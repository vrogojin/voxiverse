class_name FacetFarRing
extends Node3D
## COSMOS FP2 §5.2 / FP3 §6.1 — the planet rendered AROUND the active facet. Every non-active facet is drawn as
## a flat, low-res, terrain-coloured quad built (ONCE, cached) from its PLANARIZED corners in ABSOLUTE planet
## coords with radial relief (FP0's seam-glue). This node's transform = T_active⁻¹ (facet_transform(active)
## inverse), so the whole planet is re-placed into the active facet's flat render frame by ONE rigid transform —
## the player on the flat facet sees the faceted planet curve away, faces JOINING at the seams (no wedge).
##
## FP-S1(d) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R2 defect 4 / §8): a crossing's set_active USED to do a
## synchronous full 3456-facet rescan + re-emit + generate_normals + commit (plus first-time 25-noise-profile
## caching for every newly-front-hemisphere facet) in ONE main-thread frame — the same frame as the restream
## kickoff. That is a large part of the crossing stall. Now set_active is O(1): it updates ONLY the node transform
## (the mesh is in ABSOLUTE coords, so a rigid re-place keeps every cached facet correctly positioned) and marks a
## deferred rebuild. _process completes it OFF the crossing frame: it cache-warms newly-front-hemisphere facets
## under a per-frame ms budget (mirroring FarTerrain's discipline), then re-emits once. The headless gate drives it
## synchronously via force_rebuild(). Render-only, collision-free, voxel-worker-free (like FarTerrain).

const ENABLED := true
const CELLS := 4                     # heightmap cells per facet edge (far LOD) — k=24 facets are small
# COSMOS PLANET-VIEW §3 (B) — FP_FARRING_LIMB_DENSE tuning (all DEAD with the flag off).
const LIMB_DENSE_CELLS := 8          # silhouette-ring facets emit at this resolution (vs CELLS=4) so the limb reads round
const LIMB_DENSE_BAND := 1.0         # limb-ring half-thickness in facet angular half-widths ⇒ a ~1-facet-thick ring
                                     # (band_rad = this × the facet half-angle; |φ − θ_h| < band_rad flags the facet). The
                                     # design's 1.5 gave a ~3-facet-thick ring (~148 facets); 1.0 is a true 1-facet ring.
const LIMB_DENSE_MAX_FACETS := 128   # NEVER-OOM cap on the resident densified set. The full silhouette circumference at K=24
                                     # is ~90 facets around, so a 1-facet ring is ~90–100 (NOT the design's optimistic 40–60);
                                     # 128 gives headroom + the trim binds hard. Mesh delta ~+8 KB/facet ⇒ ≲ 1.0 MB peak.
const RELIEF := 1.0                  # blocks of radial relief per (g − SEA_LEVEL)
const BACK_CULL := 0.0               # front hemisphere only — back-side facets sit below the surface horizon
const CAMERA_FAR := 9000.0           # the planet spans ~2R; the player camera far must reach it in faceted mode
const FOG_BEGIN := 2200.0            # fog only far out, so the whole planet reads
const WARM_BUDGET_MS := 3.0          # FP-S1(d): per-frame cache-warm budget for newly-front-hemisphere facets
const ENV_WARM_BATCH := 12           # FP_ENV_WARM_ASYNC: max uncached env facets ONE worker dispatch builds before it
                                     # emits the ready subset. Off-thread ⇒ never touches the frame budget; bounded ⇒
                                     # NEVER-OOM. The orbit reveal grows ~ENV_WARM_BATCH facets per worker cycle.
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): width (texels) of the fid→slot lookup
# texture; height is derived from `FacetAtlas.facet_count()` (`_slot_indirect_dims`) so the layout always covers the
# home body's whole fid space with no wasted row (64×54 = 3456 at K=24). Well under any gl_compat texture-size floor.
const SLOT_TEX_W := 64

# FP_ENV_WARM_ASYNC instrumentation (telemetry-only, env_all path). Counts _env_weld_grid builds by the thread they
# ran on, so the perf fix is provable: OFF ⇒ all builds on MAIN; ON ⇒ builds on the WORKER, main count frozen.
static var env_build_main := 0
static var env_build_worker := 0

var _active_fid := -1
# COSMOS FAR-CRUISE NEVER-BLACK (FP_FARRING_ACTIVE_NOBLACK): the active facet to emit UN-SUNK this build (the near field
# is genuinely absent under the camera → draw at the true surface, not a sunk well), else -1. Written ONLY on the main
# thread in _noblack_guarantee (past the _async_building guard), so the worker's _emit_cached reads a value stable for
# its run — same single-writer / no-concurrent-write contract as _active_fid. -1 (and byte-identical) with the flag off.
var _noblack_unsink_fid := -1
# COSMOS FP-FIXED-FRAME re-anchor (§3): the accumulated floating-origin shift. Under the fixed frame the ring pins @
# (identity − _anchor_offset) so its ABSOLUTE mesh rides the same re-anchor as PlanetRoot. ZERO with the flag off.
var _anchor_offset: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D
# FP_FAR_SMOOTH (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P1): a FacetSmoothTier REPLACEMENT tier — worker-baked curved
# smooth tiles (S3/S4/S5 ladder) for the visible hemisphere, sharing THIS ring's shell material (so the map skin +
# every per-frame uniform bind apply for free). A facet leaves the heightfield/shell emit the frame its smooth tile
# commits (law 6, `visible_fids()`) — no overlay lift (P1 retires B2's `lift`; replacement, not overlay). null off (inert).
var _smooth = null
# docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): the NEW, separate, uniform-pitch smooth annulus —
# does NOT replace/interact with `_smooth` above (the old ladder is left untouched). A second small MeshInstance3D
# child of this ring, sharing its placement transform, drawing OVER the shell (no exclusion). null off (inert).
var _smooth_v2 = null
var _smooth_assign: Dictionary = {}   # fid -> tier (S3/S4/S5): the driver's own hysteresis-held request state (P1)
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q1 (FP_SMOOTH_IDLE): the driver's own fixpoint-at-rest cache.
# `_smooth_idle_sig` is the (active_fid, excluded-set) signature `_smooth_drive` computed LAST call; when a fresh call
# hashes the SAME signature AND there is no outstanding leaving/dwell handshake, the whole hop-ring/dwell/mesh-inc-
# gate/slot-loop pipeline is skipped and `_smooth_last_assign` is reused verbatim (zero allocation, zero O(res) scan).
# `_rim_last_gate_col` is the S2 collar's OWN independent gate (real player drift must still reach `_rim_assign` even
# while the top signature holds — role membership is covered by the signature, but the staggered per-facet REBAKE is
# driven by continuous movement, not by active_fid/excluded changing). All unused / always-recompute with the flag off.
var _smooth_idle_sig: String = ""
var _smooth_idle_primed := false
var _smooth_last_assign: Dictionary = {}
var _dwell_mutation_count := 0        # REVISION 3 G-FS-QUIESCE telemetry: _sticky_apply_dwell's _sticky_stale_since mutations
var _rim_last_gate_col: Vector3 = Vector3.ZERO
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): the player's ABSOLUTE world-space column, pushed once
# per frame by WorldManager.update_streaming (`set_player_column`) — the centre of the S2 near-collar disc (§2.1).
# Vector3.ZERO / never read (no S2 assignment ever fires) with the flag off.
var _player_col_abs: Vector3 = Vector3.ZERO
# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §4 (FP_FARRING_UNCOVERED_TRUE): has `set_player_column` ever been called with
# a real column? Guards the coverage test so the ZERO default (before the first push lands) never spuriously
# un-sinks the whole ring. Shares the same push as `_player_col_abs` above (world_manager.gd pushes it under
# FP_SMOOTH_RIM OR this flag) — a second reader of an existing write, not a new plumbing path.
var _unsink_have_col := false
# The FROZEN copy of (_player_col_abs, _unsink_have_col), snapshotted on MAIN in `_dispatch_async_rebuild` — the
# SAME `_async_backstop` freeze contract (:294-300): the worker's `_emit_cached(..., from_worker=true)` reads ONLY
# these, never the live main-thread-mutated pair, so it can never race a concurrent `set_player_column` call. The
# main-thread SYNC path (`_rebuild_full` / `_build_surfacetool` / `_build_fast`) reads the LIVE pair instead (safe —
# same thread). Zero / false with the flag off (never read).
var _async_unsink_col: Vector3 = Vector3.ZERO
var _async_unsink_have_col := false
# The column the last un-sink pass ARMED `_pending` against, + whether one has armed yet — the drift re-arm gate
# (`_unsink_drift_check`, called from `_process` near `_noblack_guarantee`): the un-sink pattern depends only on
# the player's column, so `_pending` is re-set only once it has drifted ≥ UNSINK_DRIFT_BLOCKS since this snapshot,
# not every frame. Unused with the flag off.
var _unsink_armed_col: Vector3 = Vector3.ZERO
var _unsink_armed := false
# §3 P3: the player column the CURRENTLY RESIDENT S2 tiles were last baked against + whether a baseline exists yet
# (`_rim_assign`'s RIM_REBUILD_BLOCKS cadence gate). Unused with the flag off.
var _rim_baked_col: Vector3 = Vector3.ZERO
var _rim_have_baked := false
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-D (FP_SMOOTH_MESH_INC on): per-facet baked baseline for the
# STAGGERED S2 rebake (one collar facet refreshed per `_rim_assign` call, never the whole collar at once — R.1.a.5).
# Empty / unused with the flag off (the legacy whole-collar `_rim_baked_col` above is used instead).
var _rim_baked_col_of: Dictionary = {}   # fid -> Vector3 (this facet's own last-baked player column)

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D (FP_RIM_CHEAP, §7.1 warmup pacing): stagger the INITIAL
# S2 assignment itself (not just the RIM_REBUILD_BLOCKS re-bake cadence above) so a cold engage never floods
# SMOOTH_S2_MAX(9) brand-new S2 builds into `_want`/the worker slots in the SAME call — the allocator-convoy spike
# (R5.3) is driven by ANY continuously-in-flight S2 build, not by how many run concurrently, so pacing must hold
# even at SMOOTH_BUILD_SLOTS=1. `_rim_pace_calls` counts `_rim_assign` invocations (≈1/frame under FP_SMOOTH_RIM,
# `_smooth_drive` runs every frame); `_rim_pace_last_call` is the count at the last NEWLY-granted S2 slot;
# `_rim_paced` records every fid that has ALREADY been granted its first S2 slot (so it keeps its place in
# `merged` every subsequent call regardless of residency — pacing gates the FIRST grant only, never un-grants).
# All unused / always-0 with the flag off (every rim-role fid is merged unconditionally, the shipped behaviour).
var _rim_pace_calls := 0
var _rim_pace_last_call := -1000000
var _rim_paced: Dictionary = {}   # fid -> true once granted its first S2 slot (paced or not)

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-A (FP_SMOOTH_STICKY): the hop-ring assignment target, a PURE
# function of the active facet alone (no cull axis), recomputed ONLY when `_active_fid` actually changes (a facet
# crossing) — never per-frame, never on a camera turn. `_sticky_stale_since` implements the dwell (§ R-A): a resident
# facet that has fallen out of `_sticky_target` is held (not dropped from the driver's request) until it has been
# stale for `SMOOTH_STICKY_DWELL_MS`, damping crossing-adjacent border oscillation. Empty / unused with the flag off.
var _sticky_active_fid := -2             # -2 (never equal to a real fid or -1) forces the first _smooth_drive() to compute
var _sticky_target: Dictionary = {}      # fid -> tier (S3/S4/S5), the current hop-ring assignment
var _sticky_stale_since: Dictionary = {} # fid -> Time.get_ticks_msec() when this resident facet first fell out of target

## FP_SMOOTH_GROW_PACE (warmup pacing extension, see the flag doc in cube_sphere.gd): the driver's own gradual-
## unlock gate over the hop-ring target, so a cold engage never hands `FacetSmoothTier.request()` the whole ~289-
## facet target in one call. `_grow_added`/`_grow_queued` only ever GROW (a fid unlocked once stays unlocked — the
## same "sticky, once resident stays" law, just reached gradually) — bounded by the total facet count, NEVER-OOM.
## `_grow_pending`/`_grow_idx` is an append-only queue + an O(1) forward cursor (never rescanned, never shifted) in
## the SAME nearest-first BFS order `_smooth_hop_assignment` produces. All empty/0/unused with the flag off.
var _grow_added: Dictionary = {}    # fid -> true, unlocked (may be requested) — monotonic, never un-set
var _grow_queued: Dictionary = {}   # fid -> true, already enqueued-or-unlocked once (dedupes repeated appends)
var _grow_pending: Array = []       # fid queue awaiting its pacing turn, nearest-first (append-only)
var _grow_idx := 0                  # cursor into _grow_pending: entries before this index have been unlocked

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-B (FP_SMOOTH_MESH_INC): the shell-commit generation handshake
# for a facet LEAVING the smooth-resident set entirely. `_shell_gen` increments every time the shell mesh actually
# COMMITS a rebuild (`_swap_in_arrays` / `_rebuild_full`); `_smooth_leaving[fid]` records the generation the facet was
# marked leaving AT — the facet is excluded from the exclusion filter (so the shell starts drawing it again) the
# INSTANT it is marked, but stays resident in the smooth tier's `assign` (never actually evicted) until `_shell_gen`
# has advanced past the recorded value, proving the shell has committed at least one mesh that includes it again —
# never a frame where NEITHER system draws the facet. Empty / unused with the flag off.
var _smooth_leaving: Dictionary = {}     # fid -> int (the _shell_gen — or, under FP_SHELL_SNAP_GEN, the _snap_gen mark — recorded when marked leaving)
var _shell_gen := 0                      # monotonically increasing: bumped at every actual shell mesh commit
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 T2 (FP_SHELL_SNAP_GEN): `_shell_gen` above bumps on EVERY commit —
# including a commit of an async build whose `visible_fids()` exclusion snapshot predates a facet's leaving-mark (a
# mesh that EXCLUDES the facet, proving nothing about the re-inclusion). `_snap_gen` is bumped instead at the exact
# instant a build's `visible_fids()` snapshot is taken (`_dispatch_async_rebuild` / `_rebuild_full`); `_async_snap_gen`
# freezes which snap-gen the IN-FLIGHT async build used (main→worker→main, mirrors `_async_fids`); `_last_committed_
# snap_gen` records the snap-gen the most recently COMMITTED build actually used (`_swap_in_arrays` / `_rebuild_full`).
# `_mesh_inc_gate` marks a newly-leaving facet with `_snap_gen + 1` (the earliest snapshot that CAN include the
# re-inclusion) and drops only once `_last_committed_snap_gen` reaches that mark — a stale in-flight build can bump
# `_shell_gen` on commit without satisfying this. All stay 0/-1/unused with the flag off.
var _snap_gen := 0
var _last_committed_snap_gen := -1
var _async_snap_gen := 0
# COSMOS PLANET-LOD-CONFIG P0 (§2.4): the last-bound §2V skin textures, cached so set_skin_active can UNBIND them at
# orbit (freeing the base map from the sampler → the shell falls back to the plain vertex-colour FarPalette backstop:
# tx.a≈0 ⇒ wt=0 ⇒ ALBEDO=v_col_raw·shade) and REBIND on descent. Untouched with FP_BLOCK_LOD_ORBIT off (never called).
var _skin_base_tex: Texture = null
var _skin_band_tex: Texture = null
var _band_meta_tex: ImageTexture = null   # FP_BAND_META_TEX: 512×1 RGBA32F reverse-map (a,b,Nx,Ny) per band layer (texelFetch, no uniform-vec cap)
var _band_meta_img: Image = null          # CPU staging for _band_meta_tex.update()
var _skin_cu_tex: Texture = null
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT, LAW S): the fid→slot LOOKUP texture — one
# R-channel-used RGBAF ImageTexture (mirrors the proven `_band_meta_tex` data-texture pattern above) sized to the
# home body's fid space (`FacetAtlas.facet_count()` texels, `_SLOT_TEX_W` wide). Texel (fid % w, fid / w) holds
# `_live_slot_of(fid)` — the CURRENT band/close-up combined slot, the same value `_slot_of` bakes into vertices on
# the shipped path. `_push_slot_indirect` is the ONLY writer (main-thread, called from `set_closeup_slots`/
# `set_band_slots` instead of `_pending = true`). null / never allocated with the flag off (zero bytes).
var _slot_img: Image = null
var _slot_tex: ImageTexture = null
var _skin_active := true              # §2V skin currently bound (true = shipped); set false while the orbit tier owns the disc
var _pos_cache: Dictionary = {}      # fid -> PackedVector3Array (ABSOLUTE planet coords; built once per facet)
var _col_cache: Dictionary = {}      # fid -> PackedColorArray
# FP_ENV_FALLBACK_EMIT: fid -> true once `_pos_cache[fid]` holds the ENV envelope (vs a cheap chord fallback still
# awaiting its worker upgrade). Distinguishes "coarse cache present" from "coarse cache is the min-envelope" so the
# orbit warm keeps dispatching until every visible facet is truly enveloped, while emitting the chord meanwhile. The
# coarse caches are NEVER erased (monotonic), so this can never go stale. Empty with the flag off (byte-identical).
var _env_done: Dictionary = {}       # fid -> true (env envelope built, not just a chord fallback)
# FP_ENV_FLOORED_ASYNC: the DENSE mirror of _env_done — fid -> true once `_bpos_cache[fid]` holds the min-ENVELOPE
# dense grid (vs a full-sink chord fallback awaiting its worker upgrade). Lets the floored warm keep dispatching to
# true dense-env convergence and lets _emit_cached pick the ε sink (env) vs the full sink (chord). Empty off.
var _benv_done: Dictionary = {}      # fid -> true (dense env envelope built, not just a dense chord fallback)
# COSMOS far-ring full coverage (docs/COSMOS-FARRING-COVERAGE-DESIGN.md §3): the SEPARATE dense caches for "backstop"
# facets (the active facet + the live-pool `_excluded` set) under FP_FARRING_FULL_COVER. Built lazily at BACKSTOP_CELLS
# (denser than the shipped CELLS=4) by _ensure_backstop_cached; the shipped _pos_cache/_col_cache stay at CELLS for the
# non-backstop horizon facets. Positions are ABSOLUTE + radial with NO sink baked in — the BACKSTOP_SINK radial push is
# applied PER EMITTED VERTEX in _emit_cached, so a facet that transitions backstop→distant across a crossing drops the
# sink automatically on the next rebuild (the cache is role-agnostic). NEVER populated with the flag off (zero cost).
var _bpos_cache: Dictionary = {}     # fid -> PackedVector3Array (dense, ABSOLUTE, un-sunk)
var _bcol_cache: Dictionary = {}
# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 (FP_FARRING_UNCOVERED_TRUE): the plain welded TRUE chord for a backstop
# facet — the SAME construction as `_ensure_backstop_chord_cached` (:2995), but kept in its OWN cache because under
# env_all `_bpos_cache` holds the ENVELOPE-MIN heights (a deliberate lower bound), not the true surface — the two
# must never be conflated. Built lazily (on demand, per backstop fid) by `_ensure_backstop_true_cached`; colour is
# unneeded (reuses `_bcol_cache`). Reaped alongside `_bpos_cache` in `_reap_mid_dense`. Empty with the flag off.
var _btrue_cache: Dictionary = {}    # fid -> PackedVector3Array (dense, ABSOLUTE, TRUE height, never sunk)
# COSMOS PLANET-VIEW §3 (B) — FP_FARRING_LIMB_DENSE. `_limb_set` is the FROZEN silhouette-ring set (fid -> true) for the
# CURRENT mesh build — facets straddling the horizon tangent, emitted at LIMB_DENSE_CELLS instead of CELLS=4. It is
# recomputed on the MAIN thread at each rebuild / async dispatch (freeze contract like `_async_backstop`) so the worker
# reads it race-free, and the dense `_limb_pos_cache`/`_limb_col_cache` are REAPED to it each refresh (resident ≤
# LIMB_DENSE_MAX_FACETS ⇒ NEVER-OOM). The limb caches mirror `_ensure_cached`'s un-sunk construction at the denser
# resolution (weld/env/planar), so a limb facet welds to its CELLS=4 coarse neighbours. All empty with the flag off
# (or on the surface) ⇒ `_is_limb_dense` false everywhere ⇒ byte-identical.
var _limb_set: Dictionary = {}       # fid -> true: on the current silhouette ring (drawn at LIMB_DENSE_CELLS)
var _limb_pos_cache: Dictionary = {} # fid -> PackedVector3Array (LIMB_DENSE_CELLS grid, ABSOLUTE, un-sunk)
var _limb_col_cache: Dictionary = {} # fid -> PackedColorArray     # fid -> PackedColorArray
# COSMOS NO-PROTRUSION FIDELITY §1 F2 (FP_MID_DENSE): the set of facets currently PROMOTED to the dense grid because
# they fall inside the ~ring-2 angular disc around the emit axis (the sub-camera / player point). A promoted facet
# warms + emits from the SAME dense _bpos_cache/env builders the backstop uses (dense + ε-sunk envelope lower bound),
# so it sharpens the mid-distance band AND stays no-protrusion-provable. Recomputed on emit-axis drift and REAPED as
# the sub-point moves (a facet that leaves the disc AND is not a live backstop frees its dense cache), so _bpos_cache
# stays bounded to backstop ∪ ring-2 (~+16 facets, the stated NEVER-OOM ceiling). Empty with FP_MID_DENSE off.
var _mid_dense: Dictionary = {}      # fid -> true: currently mid-dense-promoted
var _mid_dense_axis: Array = [2.0, 0.0, 0.0]   # last emit axis the disc was computed for (>1 sentinel ⇒ force first compute)
var _mid_dense_cos := 0.0            # cos(MID_DENSE_RINGS · facet-edge angle); computed lazily once (0 ⇒ uncomputed)
# REVISION 5 Stage A (FP_ENV_DEMAND_DISC): the env-DEMAND disc — wider than the mid-dense disc (ENV_DEMAND_RINGS =
# MID_DENSE_RINGS + 2) — bounds which coarse (non-dense-target) facets ever get upgraded from a chord to the full
# min-envelope. Same cos-threshold technique as _mid_dense_cos, computed lazily once (0 ⇒ uncomputed).
var _env_demand_cos := 0.0
# REVISION 5 Stage A/B: frozen per-dispatch state the async worker (and its warm-only pass) read — mirrors
# _async_floored/_async_backstop's existing freeze-at-dispatch pattern. _async_demand_on is ALWAYS false for an
# orbit-regime dispatch (Stage A is a floored-only fix); _async_warm_only marks the in-flight task as a cache-only
# pass (FP_WARM_EMIT_SPLIT) so _poll_async_rebuild knows to skip the mesh swap.
var _async_demand_on := false
var _async_demand_axis: Array = [0.0, 0.0, 1.0]
var _async_warm_only := false
# REVISION 5 Stage B (FP_WARM_EMIT_SPLIT): a warm-only cycle ran since the last real emit — owe ONE more real emit
# once the envelope fully converges (remaining hits 0), so the upgraded heights actually reach the GPU.
var _srf_env_dirty := false
# COSMOS-PERF L1 (§3.1): pre-TRIANGULATED per-facet caches for FP_FARRING_FAST_REBUILD. Built lazily from the grid
# caches above (only when the fast path or the equivalence gate runs → zero cost/memory with the flag off). Each holds
# the facet's 32 tris EXPANDED to 96 vertices in the EXACT order/winding _emit_cached emits — so the fast rebuild is a
# straight append_array memcpy per facet (~1728 C++ memcpys) instead of ~332k per-vertex GDScript→C++ round-trips.
# NORMALS are NOT cached: the mesh's GLOBAL smoothing (generate_normals merges vertices across facet SEAMS — proven by
# G-L1-FARRING) depends on the whole visible set, so the fast path assembles pos/col, then runs create_from +
# generate_normals (both C++, no GDScript per-vertex calls) → the normal array is BIT-IDENTICAL to the SurfaceTool path.
var _tri_pos_cache: Dictionary = {}  # fid -> PackedVector3Array (96 verts: the facet's tri soup, ABSOLUTE coords)
var _tri_col_cache: Dictionary = {}  # fid -> PackedColorArray   (96 colors, per _emit_cached order)
# COSMOS LOD-TEXTURE Phase 1 (§1.3): parallel tri-order UV/UV2 caches for the FAST assembler, built ONLY under
# FP_FACET_TEX (zero bytes / never touched with the flag off). UV = ((a+s)/K,(b+t)/K) is the facet-grid param;
# UV2 = (face, -1) selects the base-map layer (close-up slot is always -1 in Phase 1). Same push order as
# _tri_pos_cache so _build_fast's append_array carries them index-aligned into the mesh.
var _tri_uv_cache: Dictionary = {}   # fid -> PackedVector2Array (96 uvs, per _emit_cached order)
var _tri_uv2_cache: Dictionary = {}  # fid -> PackedVector2Array (96 uv2s: (face,-1))
# COSMOS LOD-TEXTURE Phase 4 (§1.2 T2t): the CLOSE-UP slot map (fid → resident layer) the shader reads via UV2.y.
# Pushed from WorldManager (main thread) each time the baker's slots_epoch bumps. `_slot_snapshot` is the FROZEN copy
# the mesh build reads — refreshed on the MAIN thread at each build entry (_rebuild_full / _dispatch_async_rebuild)
# so the async worker's _emit_cached reads a stable map for its lifetime (same freeze contract as _async_backstop).
# Empty with FP_FACET_TEX_CLOSEUP off ⇒ _slot_of returns -1 everywhere ⇒ UV2.y == -1, byte-identical to Phase 1.
var _closeup_slots: Dictionary = {}  # fid -> layer (live; written by set_closeup_slots on the main thread)
var _slot_snapshot: Dictionary = {}  # fid -> layer (frozen at build entry; read by the emit — worker-safe)
# COSMOS TEXTURED-LOD U1 (§2U.1: FP_BAND_BLOCK_MAP): the BAND slot map (fid → resident band layer). Rides UV2.y in the
# 64+ range (64+layer), TAKING PRIORITY over the close-up slot (0..63) since the band is strictly finer. Pushed from
# WorldManager when the baker's band_epoch bumps; `_band_slot_snapshot` is the frozen copy the mesh emit reads (same
# main-thread freeze contract as _slot_snapshot). Empty off FP_BAND_BLOCK_MAP ⇒ UV2.y never ≥ 64 (byte-identical).
var _band_slots: Dictionary = {}     # fid -> band layer (live; written by set_band_slots on the main thread)
var _band_slot_snapshot: Dictionary = {}  # fid -> band layer (frozen at build entry; read by the emit — worker-safe)
var _centre_cache: Dictionary = {}   # FP-S1(d): fid -> Array[3] cached centre dir (cheap; no planar-corner recompute per rebuild)
# FP-S1(d) deferred-rebuild state
var _pending := false                # a crossing requested a rebuild; _process (or force_rebuild) completes it off-frame
var _emitted: Dictionary = {}        # fid -> true: the facets in the CURRENTLY committed mesh (visible-set gate check)
var _reemit_count := 0               # diagnostics: full re-emits done (gate: set_active does NOT re-emit synchronously)
# COSMOS FP-R0 SPIKE: facets rendered as REAL rotated voxel terrains (WorldManager fills this behind
# CubeSphere.FP_R0). Their flat quad is suppressed here so the real voxels don't z-fight the ring. Empty
# on the shipped build (FP_R0 off) → the ring draws every non-active facet exactly as before, byte-identical.
var _excluded: Dictionary = {}       # fid -> true (skipped in the visible set, same as the active facet is skipped)
# COSMOS TIER-DEPTH-PRIORITY P1 (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.3): the STICKY backstop set under
# FP_TIER_STICKY_BACKSTOP. Grown EAGERLY to active ∪ ring-1 (make-before-break: a facet is drawn sunk BEFORE it
# enters the pool) and shrunk LAZILY (a departing facet holds its backstop role STICKY_HOLD role-events so it never
# reverts to an unsunk coarse quad while near meshes may still be applied). `_is_backstop` unions this. Empty with
# the flag off → `_is_backstop` is the shipped active∪`_excluded`, byte-identical. `_sticky_hold` is the per-fid
# remaining-hold countdown driving the lazy shrink; recomputed on every set_active/set_pool_excluded (a role-event).
var _sticky: Dictionary = {}         # fid -> true (currently a sticky backstop)
var _sticky_hold: Dictionary = {}    # fid -> int (role-events left before this ex-target may drop out of _sticky)
# COSMOS TIER-DEPTH-PRIORITY P1 gate visibility: which fids were emitted AS BACKSTOP (sunk) in the CURRENTLY committed
# mesh — the make-before-break invariant is "every pool facet is an emitted backstop at the moment near meshes apply",
# and that is a property of the LAST rebuild's roles, not the live `_is_backstop`. Recorded at each rebuild/swap.
var _emitted_backstop: Dictionary = {}   # fid -> true (drawn sunk in the committed mesh)
# COSMOS TEXTURED-LOD U2 (FP_FARRING_CULL_COVERED, §2U.3 + round-2 live-perf fix): the per-cell occlusion-cull state.
# `_cull_cover_query` is the near-coverage callable (fid, fid-lattice AABB) -> bool, routed to module_world.skin_near_meshed;
# INVALID (no module / fallback path) ⇒ cull inert (byte-identical). TWO masks, DECOUPLED, so a full far-ring rebuild
# (≈1 s SYNC) never fires per probe as coverage churns under live streaming:
#   `_cull_mask`      — the LIVE per-cell hysteresis output, updated EVERY probe (1 = this 26-block cell is confirmed
#                       covered). Drives the rebuild DECISION only; the emit never reads it.
#   `_committed_cull` — the SNAPSHOT the current mesh reflects; the EMIT (`is_cell_culled`) reads THIS. Only written at a
#                       rebuild: APPLY (settled) copies the live mask; FLUSH (safety) clears it to full emission.
# `_cull_streak` is the matching per-cell consecutive-covered-read count (the CULL_CONFIRM=2 hysteresis). All pruned to
# the live backstop set each probe ⇒ ≤ ~16 × 256 B, bounded (NEVER-OOM). Empty / never read with the flag off.
# `_cull_changed` latches a LIVE-mask flip within one probe pass (settle detector); `_cull_stable_probes` counts
# consecutive no-change probes; `_cull_last_ms` throttles the probe to CULL_REAP_MS; `_cull_last_reemit_ms` rate-limits
# the APPLY rebuild; `_cull_reemit_count` is the rebuild tally the cost gate asserts is bounded.
var _cull_cover_query: Callable = Callable()
var _cull_mask: Dictionary = {}          # fid -> PackedByteArray(BACKSTOP_CELLS²): LIVE 1 = culled (confirmed covered)
var _committed_cull: Dictionary = {}     # fid -> PackedByteArray(BACKSTOP_CELLS²): what the CURRENT mesh emits (read by is_cell_culled)
var _cull_streak: Dictionary = {}        # fid -> PackedByteArray(BACKSTOP_CELLS²): consecutive covered-read count
var _cull_changed := false               # a LIVE-mask bit flipped this probe pass (resets the settle counter)
var _cull_stable_probes := 0             # consecutive probes with NO live-mask change (settle detector)
var _cull_last_ms := 0                   # throttle clock for the coverage re-probe (CULL_REAP_MS)
var _cull_last_reemit_ms := 0            # last APPLY rebuild wall-ms (rate-limit ≥ CULL_REBUILD_MS)
var _cull_reemit_count := 0              # far-ring rebuilds this cull has triggered (bounded — G-CV-NOCHURN-COST)
# COSMOS-PERF STEP 2 (FP_FARRING_ASYNC_REBUILD): off-main-thread rebuild state. The worker assembles the mesh DATA
# (per-vertex emit + generate_normals + commit_to_arrays — pure CPU, NO RenderingServer) on the WARMED, read-only
# per-facet caches; the main thread swaps the finished ArrayMesh in (the only RenderingServer touch). Single-flight
# (_async_building), double-buffered (the old _mi.mesh stays visible until the swap), happens-before via the worker
# pool's is_task_completed (main writes _async_fids before add_task; worker writes _async_arrays before returning).
var _async_task_id := -1
var _async_building := false
var _async_fids := PackedInt32Array()   # the visible set the in-flight worker is building (main → worker; read-only during)
var _async_arrays: Array = []           # worker → main: the committed surface arrays (built off-thread, swapped on main)
# COSMOS far-ring full coverage (§4): the FROZEN backstop set for the in-flight worker. `_is_backstop` reads `_excluded`,
# which set_pool_excluded MUTATES on the main thread mid-crossing — so the worker must NOT evaluate the role live (that
# would race the dict). The role is snapshotted here on the main thread at dispatch (fid -> true); the worker only reads
# this frozen dict, preserving the existing "worker reads read-only per-facet state" contract. Empty with the flag off.
# FP_MID_DENSE: this dict is now the frozen DENSE-TARGET set (backstop ∪ mid-dense disc) — every facet the worker must
# warm + emit from the dense cache. With FP_MID_DENSE off it is exactly the shipped backstop set (byte-identical).
var _async_backstop: Dictionary = {}
# V2-3b (FP_SMOOTH_V2_EXCL_BLKLOD, docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4): the FROZEN set of facets `_smooth_v2`
# has COMMITTED resident (`FacetSmoothV2.is_resident`) at dispatch time, so a worker-thread build never touches
# `_smooth_v2._tiles` live — that Dictionary is main-thread-owned (mutated by `_smooth_v2.step()`/`_commit()`),
# exactly the same hazard class `_async_backstop` itself exists to avoid for `_excluded`. Snapshotted on MAIN in
# `_dispatch_async_rebuild()`, read-only for the worker's lifetime. The main-thread SYNC path (`_build_surfacetool`)
# reads `_smooth_v2.is_resident()` LIVE instead (safe — same-thread, mirrors `_is_backstop`'s live-on-sync-path/
# frozen-on-async-path precedent at `_emit_cached`'s doc comment). Off / no `_smooth_v2` ⇒ always empty.
var _async_v2_resident: Dictionary = {}
# FP_MID_DENSE: the frozen mid-dense subset of the dense-target set (promoted, NOT a live backstop). Lets the worker /
# swap book-keeping tell a mid-distance promotion (which draws COARSE as a fallback until its dense cache is warmed —
# it is NOT under a near mesh, so a hole would flicker) apart from a true backstop (covered by near voxels; filtered).
var _async_mid: Dictionary = {}
# FP_ENV_WARM_ASYNC: the FROZEN "this worker warms its own uncached env caches" decision for the in-flight build.
# Snapshotted on the main thread at dispatch (orbit + env_all + async only) so the worker's warm/emit is stable for
# its lifetime; false ⇒ the shipped read-only worker (caches pre-warmed on main). Never changes mid-run.
var _async_env_warm := false
# FP_ENV_FLOORED_ASYNC: frozen at dispatch — is this a FLOORED-regime warm (near terrain present ⇒ dense targets must
# emit SUNK, chord or env)? Distinguishes the floored dense-chord path from the orbit path (backstop role off) in the
# worker. False in orbit / off ⇒ the worker's dense handling is the shipped orbit behaviour.
var _async_floored := false
# FP_ENV_FALL_HOLD: frozen at dispatch — this dispatch is CHORD-ONLY (fill coverage, emit, but do NO expensive env
# builds). Set while the player falls fast: the worker keeps hole=0 with cheap chords (no env alloc firehose ⇒ no
# convoy), and the driver only dispatches when coverage actually changes (no continuous whole-shell re-emit churn).
var _async_chord_only := false
# FP_ENV_FALL_HOLD: set true by WorldManager while the player is descending fast — pauses the env-upgrade dispatch
# (chords keep coverage) so the worker's allocation firehose stops stalling the shared WASM allocator / physics tick.
var _fall_hold := false
# FP_ENV_RESUME_PACED: ms of the last floored ENV-upgrade dispatch — throttles the touchdown resume burst.
var _last_env_dispatch_ms := 0
# T2e (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-rebuild build/swap timing records, drained by WorldManager →
# RemoteBridge (take_events) so the §2.2c "zero-queue crossing stall" (far-ring re-emit prime suspect) is convicted or
# acquitted in one run. Bounded FIFO (NEVER-OOM: a drain-less headless session can never grow it). `_async_build_us` is
# the off-thread worker build wall time, written by the worker before it returns and read by main after is_task_completed
# (same happens-before as _async_arrays), so the async event carries a real build_ms alongside its main-thread swap_ms.
const EVENTS_MAX := 16
var _events: Array = []
var _async_build_us := 0

# COSMOS-ORBITAL-SHELL S1 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3): the CAMERA-radial emitted-set law under
# FP_SHELL_CAMERA_SET. Off-surface the emit cull axis becomes the sub-camera direction ĉ (ABSOLUTE planet space)
# with an altitude-derived cap θ_emit, re-emitted on angular drift — so the whole VISIBLE cap renders from any
# altitude/longitude (fixing the far-hemisphere-blank-from-orbit bug), not just the active facet's hemisphere.
# `_cam_set` false ⇒ the shipped active-facet law runs verbatim (byte-identical). ĉ + cap are a plain [x,y,z]
# Array + a cos threshold so _front_visible's dot test is unchanged. The re-emit reuses the EXISTING
# _pending/_warm_front/_process/async/swap pipeline (only the cull axis + refresh trigger change).
var _cam_set := false                       # the camera-set law currently governs the emitted set (off-surface, flag on)
var _emit_axis: Array = [0.0, 0.0, 0.0]     # ĉ (ABSOLUTE): the emit cull axis when _cam_set
var _emit_cos := BACK_CULL                  # cos(θ_emit): the emit threshold when _cam_set
var _emit_dir_last: Array = [0.0, 0.0, 0.0] # ĉ at the last re-emit (angular-drift trigger)
var _emit_thetah_last := -1.0               # θ_h at the last re-emit (radial-drift trigger)
var _emit_floored_last := false             # the surface-floor state at the last re-emit (re-emit crisply on the OFFSURFACE_Y crossing)
# COSMOS-ORBITAL-SHELL S2 (§4): one-shot whole-planet coarse-cache warm, armed after a sustained off-surface dwell.
var _offsurface := false                    # set by the per-frame driver: camera radial altitude > OFFSURFACE_Y
var _offsurface_dwell := 0.0                # seconds sustained off-surface (the S2 warm arms after SHELL_PREWARM_DWELL_S)
var _prewarm_cursor := -1                   # -1 = not started; 0..6·K² = next fid to warm; ≥ total = done (one-shot)
# COSMOS-ORBITAL-SHELL S1b (§3): progressive cached-subset emit in the true-orbit regime (see SHELL_REEMIT_GROWTH).
var _emit_cached_only := false              # the current rebuild emits ONLY cache-ready facets (true-orbit progressive path)
var _last_emit_cache_size := 0             # total cached facets at the last progressive re-emit (re-emit-on-growth throttle)
var _was_done := false                      # _warm_front returned true last orbit frame (fire ONE final full emit on completion, no prewarm-churn)
# COSMOS-PERF FALL-COLLAPSE FIX A (FP_SHELL_ORBIT_IDLE): the off-surface (true-orbit) analogue of `_srf_converged`.
# The orbit branch re-ran the full 6·K² _warm_front dot scan EVERY airborne frame (the ~67 ms proc baseline the live
# fall-from-orbit telemetry shows with draws=32). Once the front is fully warmed + emitted with nothing pending, the
# scan can be skipped until the next drift snapshot re-sets `_pending` — matching the shipped surface idle frame.
var _orbit_converged := false               # front fully cached + emitted, nothing pending → skip the per-frame warm scan (FP_SHELL_ORBIT_IDLE)
var _orbit_emitted_once := false            # FP_ENV_WARM_ASYNC: a worker-warm orbit dispatch has fired at least once this engage (fill the mesh even at 0 growth)
# COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD): hold the cap during a fall — suppress the per-frame radial
# re-snapshot (the near-surface acos(R/d) blow-up) + throttle the off-surface re-emit so the synchronous rebuild
# can't fire every frame. `_snapshot_count` is the thrash diagnostic (times a re-emit was SCHEDULED) the gate reads.
var _last_snapshot_ms := 0                   # wall-ms of the last shell snapshot (throttle base for the fall-hold re-emit)
var _last_rebuild_ms := 0                    # wall-ms of the last orbit-branch _begin_rebuild (throttle base for grew re-emits)
var _snapshot_count := 0                     # diagnostics: times _shell_snapshot fired (a scheduled re-emit) — flat during a held fall
# COSMOS-PERF FALL-COLLAPSE FIX D (FP_WARM_TRUE_BUDGET, R1): O(visible) scan support. `_centre_pack` is a lazily-built
# packed array of all 6·K² facet centre-dirs — iterated inline in _warm_front_true_budget so the per-frame scan avoids
# the per-fid _centre_dir DICT lookup + the _front_visible function-call overhead (the ×25 web scan cost). Bounded (one
# fixed-size array ≤ 6·K² Vector3 ⇒ NEVER-OOM), built once. Empty (never built) off-flag.
var _centre_pack := PackedVector3Array()
# COSMOS TIER-DEPTH-PRIORITY warm-converge (FP_TIER_WARM_CONVERGE): the SURFACE progressive-emit state (isolated from the
# orbit S1b vars above so the two paths never alias). `_srf_converged` gates the idle short-circuit (no per-frame warm scan
# once the whole front is cached + emitted); `_srf_last_bcache`/`_srf_last_ccache` are the dense/coarse cache sizes at the
# last progressive emit — a grown dense cache (a new sunk backstop) re-emits immediately (kills the stale over-near quad),
# coarse growth batches at SHELL_REEMIT_GROWTH (far-horizon holes are benign). All scalars → NEVER-OOM.
var _srf_converged := false
var _srf_was_done := false
var _srf_last_bcache := 0
var _srf_last_ccache := 0
# Live-path telemetry counters/values (remote_bridge streams shell_telemetry() → disambiguate the live driver→warm→emit chain).
var _begin_rebuild_count := 0               # times _begin_rebuild fired (0 post-engage ⇒ the emit never runs = warm-gate stall)
var _warm_pass_count := 0                   # _warm_front returned true (cap fully cached in one frame)
var _warm_fail_count := 0                   # _warm_front returned false (budget spent before the cap was fully cached)
var _dbg_true_dir: Array = [0.0, 0.0, 0.0]  # the latest ABSOLUTE sub-camera direction (driver input) — compare to _emit_axis for H-C
var _dbg_d := 0.0                           # latest camera distance from the body centre
var _dbg_h := 0.0                           # latest radial altitude h = d − R
var _dbg_theta_emit_deg := 0.0              # latest θ_emit (deg)
var _dbg_scale := 1.0                       # latest SN3 scaled-body scale s (1.0 = no clamp) — H-B far-plane/placement signal

# COSMOS-PERF FALL-ALTRATE (FP_FALL_RING_HOLD): throttle state for the per-frame scaled-placement transform write.
# The 55k-triangle ring's scaled world transform changes its AABB → a culling-BVH re-insert every frame; hold it
# during a fast descent and re-apply ≤ 1/FALL_THROTTLE_MS. −1 sentinels ⇒ the first call always applies. DEAD off the flag.
var _ringhold_prev_d := -1.0
var _ringhold_prev_usec := -1
var _ringhold_apply_msec := -1

# FP_BOOT_ASYNC (perf/voxiverse-load-profile): the boot-progressive far-ring warm state. `_boot_warm` is true while the
# initial full-hemisphere cache is being filled across frames (after a bounded synchronous seed). `_boot_fids` is the
# front-hemisphere set ordered NEAREST-FIRST to the active facet (so the visible horizon warms before the off-screen
# far side); `_boot_cursor` is the next fid to warm; `_boot_last_emit_size` throttles the progressive re-emit. All inert
# (false/0/empty, never read) with the flag off ⇒ setup() runs the shipped synchronous _rebuild_full (byte-identical).
var _boot_warm := false
var _boot_fids: PackedInt32Array = PackedInt32Array()
var _boot_cursor := 0
var _boot_last_emit_size := 0
# FP_BOOT_ASYNC (round 4): HOLD the background warm until essential-ready fires (main.gd → open_boot_gate). During the
# ShaderPrewarm/pre-essential-ready window the far-ring background warm was starving the prewarm's compile frames (live
# profile: prewarm_phase1 39s at ~550ms/frame while the ring warmed 36→1716). Holding it means only the synchronous seed
# is drawn until the player is in; then the far side fills WHILE playing (fog/near field hide the pop-in). A wall-clock
# FAILSAFE opens the gate anyway so a missed release can never permanently strand the far hemisphere at the seed.
var _boot_gate_open := false
var _boot_setup_ms := 0
const BOOT_GATE_FAILSAFE_MS := 20000   # open the warm gate this long after setup even if essential-ready never signalled

## FP_BOOT_ASYNC (round 4): main.gd (via WorldManager.release_far_ring_boot_warm) calls this at essential-ready to let
## the background far-ring warm proceed — off the prewarm/compile critical path. Idempotent; no-op with the flag off.
func open_boot_gate() -> void:
	_boot_gate_open = true

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_recompute_sticky()              # TIER-DEPTH P1: seed the sticky backstop set so ring-1 is sunk from the first build (no-op with the flag off)
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarRingMesh"
	_mi.material_override = _make_material()
	add_child(_mi)
	# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): bind the (initially all -1) lookup
	# texture right away so the shader's sampler is never left unbound before the first real slot-map push. No-op
	# with the flag off (byte-identical).
	_push_slot_indirect()
	# FP_FAR_SMOOTH (B2): the smooth-tile overlay, sharing this ring's material (child of self ⇒ inherits the placement
	# transform). Inert off (never constructed) ⇒ byte-identical.
	if CubeSphere.FP_FAR_SMOOTH:
		_smooth = FacetSmoothTier.new()
		_smooth.setup_instance(self, _mi.material_override, active_fid)
	# docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): the NEW clean-slate smooth annulus — a SEPARATE
	# instance/mesh from `_smooth` above (never both interacting); own ShaderMaterial (not the shell's), own child
	# MeshInstance3D. Inert off (never constructed) ⇒ byte-identical.
	if CubeSphere.FP_SMOOTH_V2:
		_smooth_v2 = FacetSmoothV2.new()
		_smooth_v2.setup_instance(self, active_fid)
	# FP_BOOT_ASYNC: cache only a bounded proximity seed synchronously, then warm the rest across frames (see _boot_begin
	# / _boot_warm_step). Off ⇒ the shipped synchronous full build (spawn masked by the ShaderPrewarm hold), byte-identical.
	if CubeSphere.FP_BOOT_ASYNC:
		_boot_begin()
	else:
		_rebuild_full()              # initial build — synchronous (spawn is masked by the ShaderPrewarm hold)
	set_process(true)

## FP_BOOT_ASYNC: seed the far ring with a bounded, nearest-first subset of the front hemisphere synchronously (covering
## the spawn horizon the fog/near field do not), emit it, and arm the per-frame progressive warm for the remainder. Uses
## the SAME _emit_cached_only / _ensure_emit_cached path the true-orbit progressive emit uses, so the mesh is index-aligned
## and every downstream consumer is unchanged.
func _boot_begin() -> void:
	_boot_setup_ms = Time.get_ticks_msec()
	_boot_fids = _order_front_by_proximity()
	var seed := mini(CubeSphere.BOOT_SEED_FACETS, _boot_fids.size())
	for i in range(seed):
		_ensure_emit_cached(_boot_fids[i])
	_boot_cursor = seed
	_boot_warm = _boot_cursor < _boot_fids.size()
	_emit_cached_only = true          # emit only the cached (growing) subset — visible_fids() cache-filters
	_rebuild_full()                   # draws the seed now
	_boot_last_emit_size = _pos_cache.size() + _bpos_cache.size()

## FP_BOOT_ASYNC: the front-hemisphere fids ordered by DESCENDING alignment to the active facet's centre (nearest first),
## so the visible local horizon warms before the off-screen far side. Cheap dot-product sort over ~1716 dirs (once).
func _order_front_by_proximity() -> PackedInt32Array:
	var fids := visible_fids()        # full front set (active/excluded already filtered on the surface)
	var acd := _centre_dir(_active_fid)
	var scored: Array = []
	scored.resize(fids.size())
	for i in fids.size():
		var cd := _centre_dir(fids[i])
		scored[i] = [-(cd[0] * acd[0] + cd[1] * acd[1] + cd[2] * acd[2]), int(fids[i])]  # negate → ascending sort = nearest first
	scored.sort()
	var out := PackedInt32Array()
	out.resize(scored.size())
	for i in scored.size():
		out[i] = int((scored[i] as Array)[1])
	return out

## FP_BOOT_ASYNC: warm the next batch of far-ring facet caches under a per-frame budget, re-emitting the growing cached
## subset every SHELL_REEMIT_GROWTH facets (and once at completion). When the whole front is cached it restores the
## shipped full-emit path (_emit_cached_only=false) and requests one clean rebuild. Runs on the main thread — no worker.
func _boot_warm_step() -> void:
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	while _boot_cursor < _boot_fids.size():
		_ensure_emit_cached(_boot_fids[_boot_cursor])
		_boot_cursor += 1
		if Time.get_ticks_usec() - t0 > budget_us:
			break
	var done := _boot_cursor >= _boot_fids.size()
	var sz := _pos_cache.size() + _bpos_cache.size()
	if done or (sz - _boot_last_emit_size) >= CubeSphere.SHELL_REEMIT_GROWTH:
		_boot_last_emit_size = sz
		_emit_cached_only = true
		_rebuild_full()               # emit the grown cached subset
	if done:
		_boot_warm = false
		_emit_cached_only = false     # everything cached → restore the shipped full-emit for later crossings/re-emits
		_pending = true               # one clean full rebuild next frame (all cached ⇒ identical to the shipped mesh)

## FP_BOOT_ASYNC introspection for verify_boot_async.gd — read-only. Facets whose emit cache is built so far.
func boot_cached_count() -> int:
	return _pos_cache.size() + _bpos_cache.size()
## The full front-hemisphere facet count (the target the boot warm converges to).
func boot_front_total() -> int:
	return visible_fids().size()
## Still filling the initial cache across frames?
func boot_warming() -> bool:
	return _boot_warm

## FP3 §6.1 / FP-S1(d) crossing: re-place the planet into facet `new_fid`'s render frame (rigid, O(1)) and DEFER the
## exclusion/terminator re-emit + any new-facet noise caching to _process (off the crossing frame, under a budget).
## The existing merged mesh is in ABSOLUTE coords, so the transform update alone keeps every cached facet correctly
## placed; only B's quad (now the active facet → should be excluded) and the just-left A's quad (now visible) plus a
## thin terminator band are transiently stale for the ≤1-2 frames until the deferred re-emit lands.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = _placement_xform()   # rigid re-place (cheap); identity under FP-FIXED-FRAME (no re-place)
	_recompute_sticky()              # TIER-DEPTH P1: grow the sticky set to the NEW active's ring-1 (no-op with the flag off)
	# docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): residency is a PURE function of the active facet —
	# recomputed ONLY here, on a real crossing. No-op / null with the flag off.
	if _smooth_v2 != null:
		_smooth_v2.set_active(new_fid)
	# COSMOS-ORBITAL-SHELL live fix: in orbit the emitted set is CAMERA-axis-driven (not active-facet-driven), and the
	# mesh is absolute (the transform re-place above already follows the new active facet), so a facet crossing does
	# NOT change the emitted set — its _pending would force a redundant full rebuild every ~3 frames as the active
	# facet churns under the orbit ground-track. Skip it off-surface; the camera driver re-emits on real drift. On the
	# surface / flag-off _shell_orbit() is false ⇒ the shipped deferred re-emit fires exactly as today (byte-identical).
	if not _shell_orbit():
		_pending = true

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P1: drive the smooth-tile REPLACEMENT ladder. Re-ranks the visible hemisphere
## nearest-first from the active facet EVERY call (cheap bounded BFS, §7.2 "worker starvation" precedent — the ranking
## itself is main-thread and O(visible hemisphere), only the tile BUILD is off-thread), re-requests the hysteresis-held
## {facet → tier} assignment, then pumps the worker build/commit/rebuild. Sets `_pending` the frame residency actually
## changes so the shell's next emit honours the exclusion law (a facet just left/joined the smooth-resident set).
## §3 P3 (FP_SMOOTH_RIM): folds the S2 near-collar assignment (active ∪ live-pool) into the `assign` dict BEFORE
## `request()`, so the driver dispatches S2 and S3/S4/S5 builds through the ONE existing worker-slot/commit/dirty-tier
## machinery (no separate pump). `_rim_assign` returns a NEW merged dict rather than mutating `assign` in place — GDScript
## Dictionaries are reference types, and `_smooth_next_assignment` already stashed THIS SAME `assign` object into
## `_smooth_assign` (the S3/S4/S5 hysteresis state); mutating it in place would leak S2 entries into next frame's
## pass-1 hysteresis scan, which only knows the S3/S4/S5 `counts` keys (a `Dictionary` "out of bounds" — hit and
## fixed during gate development). Off ⇒ `_rim_assign` is never called — byte-identical.
## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q1 (FP_SMOOTH_IDLE, LAW Q — "every far subsystem exposes a
## terminal state and reaches it in bounded time with zero input"): `idle_on` defaults to the flag so every real
## caller (`_process`) gets the const's value while a headless gate can force it on/off without flipping the
## compile-time literal (mirrors `build_tile`'s `normal_lit` param). When idle-gating is on, hash a cheap signature
## of the ONLY two things that can change the hop-ring/rim ROLE assignment — `_active_fid` (a crossing) and the
## `_excluded` keys (a live-pool churn) — and, if it repeats AND neither a leaving-handshake (`_smooth_leaving`) nor
## a dwell hold (`_sticky_stale_since`) is outstanding (those need per-frame wall-clock/gen re-checking regardless),
## reuse last call's fully-merged `assign` verbatim: the hop-ring/dwell O(res) scan, `_mesh_inc_gate`'s O(res) scan,
## and the R-C per-facet slot loop all skip entirely. The S2 collar's staggered rebake keeps its OWN ≥1-block
## player-drift gate (`_rim_last_gate_col`) independent of the signature — real movement must still reach it even
## while active_fid/excluded hold (role membership itself IS covered by the signature — only the rebake needs this).
## `FacetSmoothTier.request()`'s own unchanged-`_want` early-out is a second, independent line of defence. Off ⇒
## every branch below behaves exactly as REV2 shipped it (byte-identical). The REV2 flags are ALSO exposed as
## defaulted params (mirroring `idle_on`) purely so a headless gate can force the FULL REV2+REV3 pipeline on without
## flipping the compile-time consts — every real caller (`_process`) still gets the shipped const values.
## `grow_on` (FP_SMOOTH_GROW_PACE, see the flag doc in cube_sphere.gd): gradually unlocks the hop-ring target into
## `_want` instead of handing the whole ~289-facet result to `request()` in one call — the warmup flood fix. Folded
## into `pending_handshake` (growth still draining ⇒ the Q1 idle-reuse fixpoint must NOT latch early, or `_want`
## would freeze at whatever partial subset the first call granted) and applied ONLY inside the `sticky_on` branch
## (the legacy camera-ranked `else` path predates R-A and is not paced — REV2+ callers always pass sticky_on=true).
func _smooth_drive(idle_on := CubeSphere.FP_SMOOTH_IDLE, sticky_on := CubeSphere.FP_SMOOTH_STICKY,
		rim_on := CubeSphere.FP_SMOOTH_RIM, mesh_inc_on := CubeSphere.FP_SMOOTH_MESH_INC,
		skin_slot_on := CubeSphere.FP_SMOOTH_SKIN_SLOT, grow_on := CubeSphere.FP_SMOOTH_GROW_PACE) -> void:
	var growing := grow_on and _grow_idx < _grow_pending.size()
	var pending_handshake := idle_on and (not _smooth_leaving.is_empty() or not _sticky_stale_since.is_empty() or growing)
	var sig := ""
	var reuse := false
	if idle_on:
		sig = _smooth_idle_signature()
		reuse = _smooth_idle_primed and not pending_handshake and sig == _smooth_idle_sig
	var assign: Dictionary
	if reuse:
		assign = _smooth_last_assign   # LAW Q fixpoint: bit-identical inputs, no outstanding handshake — zero recompute
	elif sticky_on:
		# REVISION 2 LAW R-A: hop-ring residency — camera-independent, recomputed only on a facet crossing (below),
		# with a dwell before an out-of-band facet actually leaves the driver's request. Replaces the shipped
		# per-frame camera-culled BFS ranking (`_smooth_ranked_fids`/`_smooth_next_assignment`) entirely.
		if _active_fid != _sticky_active_fid:
			_sticky_target = _smooth_hop_assignment(_active_fid)   # a crossing — the ONLY time this recomputes
			_sticky_active_fid = _active_fid
			if grow_on:
				_grow_note_new_target(_sticky_target, _active_fid)
		assign = _sticky_apply_dwell(_sticky_target)
		if grow_on:
			_grow_advance(CubeSphere.SMOOTH_GROW_PER_FRAME)
			assign = _grow_filter(assign)
	else:
		var ranked := _smooth_ranked_fids(_active_fid)
		assign = _smooth_next_assignment(ranked)
	if rim_on:
		# Q1: role membership (active ∪ excluded) is already covered by `sig` — while reusing, only the STAGGERED
		# per-facet rebake (driven by continuous player drift, not by a role change) still needs its own gate.
		var need_rim := true
		if idle_on and reuse:
			need_rim = _player_col_abs.distance_to(_rim_last_gate_col) >= 1.0
		if need_rim:
			assign = _rim_assign(assign)
			_rim_last_gate_col = _player_col_abs
	if mesh_inc_on and (not reuse or pending_handshake):
		# REVISION 2 LAW R-B: a facet no longer in `assign` (dwell elapsed / rim dropped it) is not simply handed to
		# `request()` for eviction — it is held resident until the shell has actually re-committed a mesh that draws
		# it again (see `visible_fids()`'s `_smooth_leaving` check above). `_mesh_inc_gate` implements that handshake.
		assign = _mesh_inc_gate(assign)
	var slots := {}
	if skin_slot_on and not reuse and not CubeSphere.FP_SLOT_INDIRECT:
		# REVISION 2 LAW R-C: freeze THIS batch's skin slot for every requested facet (main-thread only — `_slot_of`
		# reads the frozen `_band_slot_snapshot`/`_slot_snapshot`, refreshed on main by `_refresh_slot_snapshot`).
		# Q1: skipped while reusing — `request()` early-outs on an unchanged `_want` regardless of `slots`, so a
		# freshly-recomputed-but-unused slot map would be wasted work (the mesh-baked slot staleness this implies is
		# Q2's fix — R3.1.d, already true today independent of this gate).
		# Q2 (FP_SLOT_INDIRECT): this whole per-facet `_slot_of` loop retires — `FacetSmoothTier._build_worker`
		# stamps `float(fid)` onto every tile's UV2.y regardless of `slots` (LAW S: geometry carries only the stable
		# fid; the shader resolves the live slot itself), so freezing a slot snapshot here would be dead work.
		for fid in assign.keys():
			slots[int(fid)] = _slot_of(int(fid))
	_smooth.request(assign, slots, idle_on)
	var _t_step := Time.get_ticks_usec()
	_smooth.step(idle_on)
	_dbg_step_ms = (Time.get_ticks_usec() - _t_step) / 1000.0
	if idle_on:
		_smooth_last_assign = assign
		_smooth_idle_sig = sig
		_smooth_idle_primed = true
	if _smooth.consume_changed():
		_pending = true

## REVISION 3 Q1: the cheap assignment-driving-input signature — (active_fid, sorted excluded-set keys). Stringified
## so comparison is a plain `==` (no Array-of-Array equality assumption needed) and the excluded set is tiny
## (≤ POOL_MAX_NEIGHBOURS+1 in practice) so sorting it is O(1)-ish. Does NOT include the player column (the S2 rebake
## gate is separate, `_rim_last_gate_col`) or any shell/skin generation counter (those are Q2/Q3's job to quiesce —
## coupling this signature to them would defeat the Q1 gate whenever an unrelated skin bake is still converging).
func _smooth_idle_signature() -> String:
	var keys := _excluded.keys()
	keys.sort()
	return "%d|%s" % [_active_fid, keys]

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-A (FP_SMOOTH_STICKY): the hop-ring assignment target — a
## PURE function of `active` alone (a bounded BFS over `FacetAtlas.seam_neighbour`, NO cull-axis / `_front_visible`
## test anywhere in it — the root cause of the shipped camera-coupled flicker, R.1.a.2). Ring 1-2 → S3, ring ≤5 → S4,
## ring ≤10 → S5 (`SMOOTH_STICKY_S3_HOP`/`S4_HOP`/`S5_HOP`). Backstop-role facets (active ∪ live-pool — the near
## voxels' own collar, handled by `_rim_assign`'s S2) are excluded exactly as the shipped ranking already excludes
## them. Deterministic traversal order (E/W/N/S) plus a per-tier residency cap trim keeps the SAME 289-facet worst
## case the shipped ladder ships (defensive — in practice hop-radius 10 stays well inside the caps).
func _smooth_hop_assignment(active: int) -> Dictionary:
	var assign := {}
	var visited := {active: true}
	var frontier := [active]
	var slots := [FacetAtlas.S_EAST, FacetAtlas.S_WEST, FacetAtlas.S_NORTH, FacetAtlas.S_SOUTH]
	var counts := {FacetSmoothTier.S3: 0, FacetSmoothTier.S4: 0, FacetSmoothTier.S5: 0}
	var hop := 0
	while not frontier.is_empty() and hop < CubeSphere.smooth_s5_hop():
		hop += 1
		var next_frontier := []
		for fid in frontier:
			for slot in slots:
				var nb := FacetAtlas.seam_neighbour(int(fid), slot)
				if nb < 0 or visited.has(nb):
					continue
				visited[nb] = true
				next_frontier.append(nb)
				if _is_backstop(nb):
					continue   # near-voxel-owned collar role — assigned separately by _rim_assign (S2), never the ladder
				var tier := -1
				if hop <= CubeSphere.SMOOTH_STICKY_S3_HOP:
					tier = FacetSmoothTier.S3
				elif hop <= CubeSphere.SMOOTH_STICKY_S4_HOP:
					tier = FacetSmoothTier.S4
				elif hop <= CubeSphere.smooth_s5_hop():
					tier = FacetSmoothTier.S5
				if tier < 0:
					continue
				if int(counts[tier]) >= FacetSmoothTier.residency_for_tier(tier):
					continue   # defensive NEVER-OOM trim (the same 289-facet ledger the shipped ladder ships)
				assign[int(nb)] = tier
				counts[tier] = int(counts[tier]) + 1
		frontier = next_frontier
	return assign

## FP_SMOOTH_GROW_PACE warmup pacing (see the flag doc in cube_sphere.gd): `active`'s direct, non-backstop seam
## neighbours — exactly the hop=1 frontier `_smooth_hop_assignment`'s BFS visits first. These are unlocked
## IMMEDIATELY (never queued/paced) so the near↔far seam is covered on the very first `_smooth_drive` call of a
## cold engage — the pacing only trickles the OUTER hemisphere (hop ≥ 2). Pure, O(4).
func _smooth_ring1_fids(active: int) -> Array:
	var out := []
	for slot in [FacetAtlas.S_EAST, FacetAtlas.S_WEST, FacetAtlas.S_NORTH, FacetAtlas.S_SOUTH]:
		var nb := FacetAtlas.seam_neighbour(active, slot)
		if nb >= 0 and not _is_backstop(nb):
			out.append(nb)
	return out

## FP_SMOOTH_GROW_PACE: called only when `target` was FRESHLY (re)computed (a cold engage or a real crossing).
## Ring-1 fids (see `_smooth_ring1_fids`) are unlocked into `_grow_added` right away; every OTHER fid in `target`
## not already seen (`_grow_queued`) is appended to `_grow_pending` in `target`'s own nearest-first BFS key order
## (Dictionary preserves insertion order — the same order `_smooth_hop_assignment` built it in). Fids already
## unlocked/queued from an EARLIER target (a facet that stayed in range across a crossing) are left exactly where
## they are — this queue is append-only and never rebuilt from scratch, so an in-progress pace is never restarted.
func _grow_note_new_target(target: Dictionary, active: int) -> void:
	var ring1 := {}
	for f in _smooth_ring1_fids(active):
		ring1[int(f)] = true
	for fid in target.keys():
		var f := int(fid)
		if _grow_queued.has(f):
			continue
		_grow_queued[f] = true
		if ring1.has(f):
			_grow_added[f] = true   # hop=1 fast path — never paced
		else:
			_grow_pending.append(f)

## FP_SMOOTH_GROW_PACE: unlock at most `cap` more fids from the front of `_grow_pending` (an O(1) index cursor —
## never re-scanned, never shifted). A no-op (O(1)) once `_grow_idx` has reached the end — the fully-grown steady
## state does zero further work here.
func _grow_advance(cap: int) -> void:
	var n := 0
	while n < cap and _grow_idx < _grow_pending.size():
		var f := int(_grow_pending[_grow_idx])
		_grow_idx += 1
		_grow_added[f] = true
		n += 1

## FP_SMOOTH_GROW_PACE: filter `assign` down to only fids already unlocked (`_grow_added`) — the driver's actual
## request to `FacetSmoothTier.request()`/`_rim_assign`/`_mesh_inc_gate` this call. A fid present in `assign` but
## not yet unlocked simply stays on whatever role it already had (shell/backstop) until its pacing turn — never a
## hole (the shipped emit-exclusion/make-before-break laws only ever exclude a fid once ITS OWN smooth tile is
## actually resident, which can't happen before it's unlocked).
func _grow_filter(assign: Dictionary) -> Dictionary:
	var out := {}
	for fid in assign.keys():
		var f := int(fid)
		if _grow_added.has(f):
			out[f] = assign[fid]
	return out

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-A (dwell): a currently-resident facet that fell out of
## `target` is NOT immediately handed to `FacetSmoothTier.request()` for eviction — it stays in the returned dict at
## its EXISTING tier until it has been stale for `SMOOTH_STICKY_DWELL_MS`, damping crossing-adjacent thrash. A facet
## that re-enters `target` before the dwell elapses has its stale timer cancelled (still resident the whole time —
## the flag never actually dropped it). Pure w.r.t. `target`; reads/writes only `_sticky_stale_since` + `_smooth`.
func _sticky_apply_dwell(target: Dictionary) -> Dictionary:
	var out := target.duplicate()
	var now := Time.get_ticks_msec()
	for fid in _smooth.resident_fids():
		var f := int(fid)
		if int(_smooth.tier_of(f)) == FacetSmoothTier.S2:
			continue   # the S2 collar is driven by _rim_assign, never by the hop-ring dwell
		if target.has(f):
			if _sticky_stale_since.has(f):
				_sticky_stale_since.erase(f)
				_dwell_mutation_count += 1   # REVISION 3 G-FS-QUIESCE telemetry: a stale timer cancelled (re-entered target)
			continue
		if not _sticky_stale_since.has(f):
			_sticky_stale_since[f] = now
			_dwell_mutation_count += 1       # a facet just started its fall-out dwell
		if now - int(_sticky_stale_since[f]) < CubeSphere.SMOOTH_STICKY_DWELL_MS:
			out[f] = _smooth.tier_of(f)          # dwell hold — still wanted this cycle, not yet evictable
		else:
			_sticky_stale_since.erase(f)          # dwell elapsed — leave OUT of `out`; the caller may now let it go
			_dwell_mutation_count += 1
	return out

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-B (FP_SMOOTH_MESH_INC): the shell-commit handshake for a
## facet actually leaving the smooth-resident set (present in `_smooth.resident_fids()` but absent from `assign`
## after sticky-dwell/rim have had their say). The first time a facet is seen missing, it is (a) marked in
## `_smooth_leaving` — which immediately un-excludes it from `visible_fids()` so the NEXT shell rebuild draws it
## again — and (b) kept resident by re-adding it to the returned dict at its current tier (so `request()` does not
## evict it yet). Only once `_shell_gen` has advanced past the generation it was marked at (proof that a shell mesh
## commit landed while it was un-excluded) is it finally dropped from the dict, letting `request()` evict it for
## real — the smooth tile is never gone before the shell has visibly taken over.
func _mesh_inc_gate(assign: Dictionary, snap_gen_on := CubeSphere.FP_SHELL_SNAP_GEN) -> Dictionary:
	var out := assign.duplicate()
	for fid in _smooth.resident_fids():
		var f := int(fid)
		if out.has(f):
			_smooth_leaving.erase(f)
			continue
		if not _smooth_leaving.has(f):
			_pending = true                       # ask for a shell rebuild so the re-inclusion actually lands
			out[f] = int(_smooth.tier_of(f))
			if snap_gen_on:
				# REVISION 3 T2 (FP_SHELL_SNAP_GEN): mark with the EARLIEST snapshot generation that can possibly
				# include the re-inclusion — the NEXT visible_fids() snapshot to be taken (`_snap_gen + 1`). A build
				# whose snapshot predates the mark (a stale in-flight async build, dispatched before this frame) must
				# NOT satisfy the drop test below even though `_shell_gen` still advances when it commits.
				_smooth_leaving[f] = _snap_gen + 1
			else:
				_smooth_leaving[f] = _shell_gen   # shipped REV2 law: mark at the current commit generation
		elif snap_gen_on:
			if _last_committed_snap_gen >= int(_smooth_leaving[f]):
				_smooth_leaving.erase(f)          # a build snapshotted AT/AFTER the mark has actually COMMITTED — safe to drop
			else:
				out[f] = int(_smooth.tier_of(f))  # no post-mark-snapshot commit yet (or it's a stale in-flight build) — stay resident
		elif _shell_gen <= int(_smooth_leaving[f]):
			out[f] = int(_smooth.tier_of(f))      # shell hasn't committed the re-inclusion yet — stay resident
		else:
			_smooth_leaving.erase(f)              # shell committed at least once since — safe to drop now
	return out

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): the S2 near-collar assignment — active ∪ live-pool
## (`_excluded`, the "backstop-role" set near voxels actually own), capped at SMOOTH_S2_MAX (a defensive trim; in
## practice active+`_excluded` ≤ 1+POOL_MAX_NEIGHBOURS(4) = 5, well inside the cap). Sticky-only ring-1 facets (in
## `_sticky` but neither active nor live-pool) are DELIBERATELY excluded — they stay on the shipped S3 ladder path
## (§3 P3: "sticky ring-1 facets stay S3"), matching what `_smooth_ranked_fids` already ranks them as. Returns a
## COPY of `assign` with the S2 entries added (no collision on the copy: `_smooth_ranked_fids` already excludes
## every backstop-role fid from `ranked`, so `_smooth_next_assignment` never assigned one of these keys) — the
## caller's `_smooth_assign` (S3/S4/S5-only hysteresis state) is left untouched.
##
## Also owns the §2.1 REBUILD CADENCE: the frozen player-column snapshot only re-baselines (forcing every currently
## resident S2 tile to re-bake against the fresh column) once the player has drifted > RIM_REBUILD_BLOCKS since the
## last bake — never a per-frame rebake. `force_rebake` is a plain evict: the facet's role falls straight BACK to
## its (still cached, still-warm) sunk backstop quad the instant it drops out of `_smooth`'s resident set (the SAME
## law-6 `visible_fids()` exclusion check, run in reverse) and stays there until the freshly-baked S2 tile re-commits
## — so there is NEVER a frame with neither the backstop nor an S2 tile resident for a pool facet (G-RIM-MBB).
##
## `cheap_on` (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D, FP_RIM_CHEAP, §7.1 warmup pacing): a
## brand-new (never-yet-`_rim_paced`) facet is only granted its FIRST S2 slot once `RIM_PACE_FRAMES` `_rim_assign`
## calls have elapsed since the last new grant — a cold engage (e.g. up to 5 backstop-role facets at once) never
## dispatches more than one fresh S2 build into `_want`/the worker slots per pacing window, however many facets
## the driver would otherwise assign simultaneously. A facet ALREADY paced (or already resident) is unaffected —
## pacing gates only the first grant, never removes a facet already in flight or built (never a hole: an unpaced
## fid simply keeps whatever role it already had — shell/backstop — until its turn, the same ≤-truth fallback
## `_rim_assign` already relies on before ANY S2 tile has committed). Off ⇒ every rim-role fid is merged
## unconditionally in the SAME call — the shipped flood, byte-identical.
func _rim_assign(assign: Dictionary, cheap_on := CubeSphere.FP_RIM_CHEAP) -> Dictionary:
	var merged := assign.duplicate()
	var rim := {}
	rim[_active_fid] = true
	for f in _excluded.keys():
		rim[int(f)] = true
	_rim_pace_calls += 1
	var count := 0
	for f in rim.keys():
		if count >= CubeSphere.SMOOTH_S2_MAX:
			break
		var fi := int(f)
		if cheap_on and not _rim_paced.has(fi) and not _smooth.is_resident(fi):
			if _rim_pace_calls - _rim_pace_last_call < CubeSphere.RIM_PACE_FRAMES:
				continue   # not this fid's turn yet — stays on its current (shell/backstop) role meanwhile
			_rim_pace_last_call = _rim_pace_calls
		_rim_paced[fi] = true
		merged[fi] = FacetSmoothTier.S2
		count += 1
	_smooth.set_rim_params(_player_col_abs)
	if CubeSphere.FP_SMOOTH_MESH_INC:
		# REVISION 2 LAW R-D/R-B: STAGGERED, IN-PLACE rebake — at most ONE drifted collar facet gets a fresh
		# `request_refresh` per call (never the whole collar simultaneously, R.1.a.5), and it is a build-then-swap
		# refresh (never an evict) so the facet is "permanently sticky ... never evicted, only swap-rebuilt" (R-D).
		for f in rim.keys():
			var ff := int(f)
			var have := _rim_baked_col_of.has(ff)
			var drift := _player_col_abs.distance_to(_rim_baked_col_of.get(ff, Vector3.ZERO)) if have else INF
			if (not have or drift > CubeSphere.RIM_REBUILD_BLOCKS) and int(_smooth.tier_of(ff)) == FacetSmoothTier.S2:
				_smooth.request_refresh(ff)
				_rim_baked_col_of[ff] = _player_col_abs
				break   # stagger: one facet dispatched this call, the rest catch up on subsequent calls
	else:
		# SHIPPED (legacy) whole-collar simultaneous evict-then-rebuild — byte-identical without FP_SMOOTH_MESH_INC.
		var drift := _player_col_abs.distance_to(_rim_baked_col) if _rim_have_baked else 0.0
		if not _rim_have_baked or drift > CubeSphere.RIM_REBUILD_BLOCKS:
			for f in rim.keys():
				if _smooth.tier_of(int(f)) == FacetSmoothTier.S2:
					_smooth.force_rebake(int(f))
			_rim_baked_col = _player_col_abs
			_rim_have_baked = true
	return merged

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2.1 (P3): R_env — the disc radius (blocks) inside which S2 vertices sit at
## (or blend from) the min-envelope height. Near view distance (`TerrainConfig.near_render_radius()`, 128 faceted) +
## RIM_STREAM_MARGIN(32); the margin exceeds RIM_REBUILD_BLOCKS(24) so near voxels can never stream in outside the
## envelope zone BETWEEN two rim rebuilds (§2.1's stated invariant).
static func rim_r_env() -> float:
	return float(TerrainConfig.near_render_radius()) + CubeSphere.RIM_STREAM_MARGIN

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): push the player's ABSOLUTE world-space column
## (WorldManager.update_streaming converts the lattice player_pos via `FacetAtlas.lattice_to_world64` before calling
## this) once per frame — the centre `_rim_assign`/`build_tile_rim` blend the S2 disc/feather against. A no-op write
## with the flag off (nothing ever reads `_player_col_abs` then).
func set_player_column(col_abs: Vector3) -> void:
	_player_col_abs = col_abs
	_unsink_have_col = true   # FP_FARRING_UNCOVERED_TRUE: a real column now exists (see the field's own doc comment)

## The active facet's visible-hemisphere neighbours, NEAREST-FIRST by BFS hop count across `FacetAtlas.seam_neighbour`
## (cross-face ring — NOT the retired in-face-only 3×3; that was a root cause of B2 being gated off, §1.3 defect 1).
## Excludes the active facet itself and any backstop facet (near voxels own those on the S3-S5 ladder; the S2
## near-collar for backstop-role facets is assigned separately by `_rim_assign`, §3 P3).
## Bounded to a modest BFS-level overshoot past the hysteresis-widened total cap so a moving player's ranking always
## covers every facet the assignment pass could possibly need, without ever walking the whole planet.
func _smooth_ranked_fids(active: int) -> Array:
	var p := _cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var visited := {active: true}
	var order := []
	var frontier := [active]
	var slots := [FacetAtlas.S_EAST, FacetAtlas.S_WEST, FacetAtlas.S_NORTH, FacetAtlas.S_SOUTH]
	var cap_total := CubeSphere.SMOOTH_S3_MAX + CubeSphere.smooth_s4_max() + CubeSphere.smooth_s5_max()
	var hyst_total := int(float(cap_total) * CubeSphere.SSE_HYST) + 16
	while not frontier.is_empty() and order.size() < hyst_total:
		var next_frontier := []
		for fid in frontier:
			for slot in slots:
				var nb := FacetAtlas.seam_neighbour(int(fid), slot)
				if nb < 0 or visited.has(nb):
					continue
				visited[nb] = true
				if not _front_visible(nb, nrm, thresh):
					continue           # back-hemisphere — not part of the visible disc, don't traverse through it
				next_frontier.append(nb)
				if nb != active and not _is_backstop(nb):
					order.append(nb)
		frontier = next_frontier
	return order

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P1: assign each ranked (nearest-first) candidate a tier (S3/S4/S5) under the
## per-tier caps (25/64/200), PROMOTE strict / DEMOTE hysteresis-lagged (`SSE_HYST` precedent, `cube_sphere.gd:1039`
## "a resident tier is only demoted past promote·SSE_HYST"): a facet already resident at tier T keeps T as long as its
## CURRENT rank stays inside T's cumulative band widened ×SSE_HYST (pass 1); every facet still unassigned then fills
## the remaining STRICT band slots nearest-first (pass 2, promotions + brand-new facets). Deterministic, no allocation
## beyond the transient rank map — the driver's own `_smooth_assign` carries the hysteresis state frame to frame.
func _smooth_next_assignment(ranked: Array) -> Dictionary:
	var rank_of := {}
	for i in range(ranked.size()):
		rank_of[int(ranked[i])] = i
	var b1 := CubeSphere.SMOOTH_S3_MAX
	var b2 := b1 + CubeSphere.smooth_s4_max()
	var b3 := b2 + CubeSphere.smooth_s5_max()
	var d1 := int(float(b1) * CubeSphere.SSE_HYST)
	var d2 := int(float(b2) * CubeSphere.SSE_HYST)
	var d3 := int(float(b3) * CubeSphere.SSE_HYST)
	var counts := {FacetSmoothTier.S3: 0, FacetSmoothTier.S4: 0, FacetSmoothTier.S5: 0}
	var assign := {}
	# Pass 1 — hysteresis hold: an already-resident facet keeps its tier while its rank stays inside the DEMOTE-widened band.
	for fid in ranked:
		var f := int(fid)
		if not _smooth_assign.has(f):
			continue
		var t: int = int(_smooth_assign[f])
		if not counts.has(t):
			continue   # defensive: this pass only understands S3/S4/S5 (a foreign tier — e.g. §3 P3's S2 — is never ranked here anyway)
		var r: int = int(rank_of[f])
		var within := false
		if t == FacetSmoothTier.S3:
			within = r < d1
		elif t == FacetSmoothTier.S4:
			within = r < d2
		else:
			within = r < d3
		if within and int(counts[t]) < FacetSmoothTier.residency_for_tier(t):
			assign[f] = t
			counts[t] = int(counts[t]) + 1
	# Pass 2 — strict nearest-first fill of whatever cap room remains (promotions to a finer tier + brand-new facets).
	for fid in ranked:
		var f := int(fid)
		if assign.has(f):
			continue
		var r: int = int(rank_of[f])
		var t := -1
		if r < b1 and int(counts[FacetSmoothTier.S3]) < CubeSphere.SMOOTH_S3_MAX:
			t = FacetSmoothTier.S3
		elif r < b2 and int(counts[FacetSmoothTier.S4]) < CubeSphere.smooth_s4_max():
			t = FacetSmoothTier.S4
		elif r < b3 and int(counts[FacetSmoothTier.S5]) < CubeSphere.smooth_s5_max():
			t = FacetSmoothTier.S5
		if t >= 0:
			assign[f] = t
			counts[t] = int(counts[t]) + 1
	_smooth_assign = assign
	return assign

## Gate/telemetry accessor: is `fid` currently drawn by the smooth tier (any tier)? False (and never null-derefs)
## with the flag off.
func is_smooth_resident(fid: int) -> bool:
	return _smooth != null and _smooth.is_resident(fid)

## FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §1.4/§2.2 step 8): the ring mesh is built in ABSOLUTE planet
## coords. When the fixed frame pins the scene @ the absolute frame (PlanetRoot @ identity) this node stays @
## identity — a crossing does NO transform write here (only the deferred exclusion/terminator re-emit remains). Off
## ⇒ T_active⁻¹, re-placing the absolute mesh into the active facet's render frame exactly as today (byte-identical).
func _placement_xform() -> Transform3D:
	if CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		return Transform3D(Basis.IDENTITY, -_anchor_offset)
	return FacetAtlas.facet_transform(_active_fid).affine_inverse()

## COSMOS SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2): the planet centre in the CURRENT render
## frame. The ring mesh is absolute + body-centred (the planet centre is v_abs = 0), so its world position is
## _placement_xform() applied to the origin — i.e. the shipped placement's translation. Frame-agnostic (folds
## in T_active⁻¹ or the fixed-frame −anchor). The SN3 driver uses this to derive d = |camera − centre| and the
## radial altitude h. DEAD unless FP_SCALED_BODY is on (only the SN3 per-frame driver calls it).
func render_centre() -> Vector3:
	return _placement_xform().origin

## COSMOS SPACE-NAV SN3 (§5.2): apply the angular-size-preserving distance clamp. Above D_ENGAGE the whole ring
## is uniformly scaled by s = min(1, D_ENGAGE/d) ABOUT the camera — screen image invariant, geometry pulled into
## the depth range at d·s = D_ENGAGE. Below D_ENGAGE s == 1 exactly ⇒ transform == _placement_xform() (the
## shipped placement, byte-identical to the near regime). The ring mesh/nodes are untouched (ZERO bytes) — only
## this node's transform changes, and only when the SN3 driver calls this (FP_SCALED_BODY on). Called per frame
## on the main thread (like set_active's rigid re-place); the async worker is unaffected (it reads only caches).
func apply_scaled_placement(cam: Vector3) -> void:
	var base := _placement_xform()
	var d := cam.distance_to(base.origin)
	var s := CosmosScale.scale_for(d, FacetAtlas.R_BLOCKS)
	_dbg_scale = s                                  # H-B telemetry: the SN3 clamp scale actually applied to the ring this frame
	# COSMOS-PERF FALL-ALTRATE (FP_FALL_RING_HOLD): off ⇒ the shipped every-frame transform write (byte-identical).
	if CubeSphere.FP_FALL_RING_HOLD:
		var now_usec := Time.get_ticks_usec()
		var vspeed := 0.0
		if _ringhold_prev_usec >= 0:
			vspeed = FallThrottle.radial_speed(_ringhold_prev_d, d, float(now_usec - _ringhold_prev_usec) / 1.0e6)
		_ringhold_prev_d = d
		_ringhold_prev_usec = now_usec
		var now_msec := Time.get_ticks_msec()
		var ms_since := (now_msec - _ringhold_apply_msec) if _ringhold_apply_msec >= 0 else 0x7fffffff
		if not FallThrottle.should_reapply(true, vspeed, ms_since):
			return                                  # hold the last scaled placement (no AABB/BVH churn this frame)
		_ringhold_apply_msec = now_msec
	transform = CosmosScale.scale_about_camera(cam, s) * base   # s == 1 ⇒ identity·base == base (near regime unchanged)

## COSMOS-ORBITAL-SHELL S1/S2 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3/§4): the per-frame camera-set driver. `cam`
## is the camera position in the CURRENT render frame (as apply_scaled_placement receives it). The mesh is in
## ABSOLUTE planet coords placed by _placement_xform() (a rigid transform), so the sub-camera radial direction in
## the mesh's ABSOLUTE space is base.basis⁻¹·(cam − render_centre) and the TRUE (unclamped, scale-free) distance is
## |cam − render_centre| — both fold through _placement_xform for either placement path (fixed-frame or legacy),
## and the SN3 scale (scale_about_camera) is screen-invariant so it never enters ĉ or d. Updates the emitted-set
## law (S1) and the off-surface flag driving the one-shot prewarm (S2). No allocation beyond the transient dir
## Array; never rebuilds inline (only sets _pending — the crossing-pipeline discipline). Called per frame by
## WorldManager under (FP_SHELL_CAMERA_SET or FP_SHELL_PREWARM); DEAD (never called) with both flags off.
func apply_camera_set(cam: Vector3) -> void:
	var base := _placement_xform()
	var rel := cam - base.origin                      # camera relative to the body centre, RENDER frame
	var d := rel.length()
	var h := d - FacetAtlas.R_BLOCKS
	_offsurface = h > CubeSphere.OFFSURFACE_Y         # S2 prewarm arming (drives the dwell in _prewarm_step)
	_dbg_d = d
	_dbg_h = h
	if not CubeSphere.FP_SHELL_CAMERA_SET:
		return                                        # S2-only run: prewarm the cache without changing the emitted-set law
	var abs_rel := base.basis.inverse() * rel         # rotate the render-frame offset back into ABSOLUTE mesh space
	if abs_rel.length() < 1.0e-6:
		return                                        # camera at the body centre (degenerate) — keep the last axis
	var u := abs_rel.normalized()
	_dbg_true_dir = [u.x, u.y, u.z]                   # H-C telemetry: the TRUE sub-camera direction the driver fed in
	shell_set_camera_abs([u.x, u.y, u.z], d, h < CubeSphere.OFFSURFACE_Y)

## COSMOS-ORBITAL-SHELL S1 (§3): the emitted-set law core, driven from the ABSOLUTE sub-camera direction `dir`
## (unit [x,y,z]), the camera distance `d` from the body centre, and whether the surface floor applies. Snapshots
## the cull axis (ĉ) + cap cos(θ_emit) and marks a deferred re-emit on first engage, on the OFFSURFACE_Y floor
## crossing, or when ĉ drifts past SHELL_SLACK_DEG − 2° / θ_h shifts > 5° (fast radial move). θ_emit is floored to
## 90° below OFFSURFACE_Y so the on-foot regime is byte-VISUALLY identical to shipped (the facets that then differ
## from the active-facet law all sit behind the limb). Pure state update + a possible _pending flag; the actual
## warm + rebuild + swap ride the EXISTING _process/async pipeline. Split out so headless gates drive it directly.
func shell_set_camera_abs(dir: Array, d: float, floored: bool) -> void:
	var r := FacetAtlas.R_BLOCKS
	var theta_h := acos(clampf(r / maxf(d, r), -1.0, 1.0))   # visible-cap angular radius (0 at/below the surface, < 90° always)
	# COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD): off-surface (airborne) carry a GENEROUS extra margin so a
	# shrinking visible cap during a descent stays inside the held cap ⇒ no radial re-emit needed. Byte-identical off
	# (extra == 0) and on the floored surface. See shell_fall_should_reemit for the matching suppressed radial trigger.
	var fall_hold := CubeSphere.FP_SHELL_FALL_HOLD and not floored
	var extra := deg_to_rad(CubeSphere.SHELL_FALL_MARGIN_DEG) if fall_hold else 0.0
	var theta_emit := minf(theta_h + deg_to_rad(CubeSphere.SHELL_RELIEF_DEG + CubeSphere.SHELL_SLACK_DEG) + extra,
			deg_to_rad(CubeSphere.SHELL_CAP_MAX_DEG))
	if floored:
		theta_emit = maxf(theta_emit, deg_to_rad(90.0))       # surface floor: keep the shipped hemisphere while near tiers are live
	_dbg_theta_emit_deg = rad_to_deg(theta_emit)
	var new_cos := cos(theta_emit)
	if not _cam_set:
		_cam_set = true                                       # first engage → snapshot + force a re-emit onto the camera axis
		_shell_snapshot(dir, new_cos, theta_h, floored)
		_last_snapshot_ms = Time.get_ticks_msec()
		return
	var drift := acos(clampf(dir[0] * _emit_dir_last[0] + dir[1] * _emit_dir_last[1] + dir[2] * _emit_dir_last[2], -1.0, 1.0))
	var dtheta := theta_h - _emit_thetah_last                 # SIGNED: > 0 = the visible cap grew (a climb); < 0 = shrank (a descent)
	var reemit := shell_fall_should_reemit(fall_hold, floored != _emit_floored_last, dtheta, drift, Time.get_ticks_msec() - _last_snapshot_ms)
	# COSMOS DEV-FLY HANG (FP_SHELL_CLIMB_NO_CHURN): below OFFSURFACE_Y the emitted cap is FLOORED to 90° and stays there
	# for every θ_h < 67° (all altitudes below ~9900 blocks), so a powered climb's growing θ_h fires the |Δθ_h| > 5°
	# trigger to re-emit an IDENTICAL hemisphere set — a redundant blocky-mesh rebuild + GL/ANGLE upload (the render-thread
	# churn suspected in the dev-fly hard-hang). Suppress the re-emit ONLY when the committed set is PROVABLY unchanged:
	# still floored, the cap cos is identical to the committed cap, and the axis has not swept. Axis drift, a floor/regime
	# crossing, or any genuine cap change all still re-emit above (correctness — no limb holes). Off ⇒ shipped (byte-identical).
	if reemit and CubeSphere.FP_SHELL_CLIMB_NO_CHURN and floored and floored == _emit_floored_last \
			and is_equal_approx(new_cos, _emit_cos) and drift <= deg_to_rad(CubeSphere.SHELL_SLACK_DEG - 2.0):
		reemit = false                                        # identical floored cap + no axis sweep → the rebuild would emit the SAME set (churn)
	if reemit:
		_shell_snapshot(dir, new_cos, theta_h, floored)
		_last_snapshot_ms = Time.get_ticks_msec()

## COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD) — the re-emit-trigger decision, split out PURE + static so
## the descent gate (G-SHELL-FALLHOLD) drives it directly with synthetic inputs (no wall-clock, no node). A floor/regime
## change ALWAYS re-emits. With `hold` OFF: the shipped reactive triggers verbatim (axis drift past slack − 2°, OR
## |Δθ_h| > 5°) — byte-identical. With `hold` ON: the per-frame radial trigger is SUPPRESSED for a shrinking cap (the
## near-surface acos blow-up during a fall) — re-emit ONLY when the cap must GROW past the held generous margin
## (a climb — else holes appear at the limb), or the axis SWEEPS past slack AND the throttle (SHELL_FALL_REEMIT_MS) has
## elapsed. `dtheta` is SIGNED (> 0 = grew); `drift` is the axis angle since the last snapshot (rad); `elapsed_ms` is
## the wall-ms since the last snapshot. Bounds the far-ring re-emit (⇒ the synchronous _rebuild_full) to ≤ 1/throttle.
static func shell_fall_should_reemit(hold: bool, floor_changed: bool, dtheta: float, drift: float, elapsed_ms: int) -> bool:
	if floor_changed:
		return true
	var swept := drift > deg_to_rad(CubeSphere.SHELL_SLACK_DEG - 2.0)
	if not hold:
		return swept or absf(dtheta) > deg_to_rad(5.0)       # shipped reactive trigger (byte-identical)
	if dtheta > deg_to_rad(CubeSphere.SHELL_FALL_MARGIN_DEG):
		return true                                          # visible cap OUTGREW the held cap (a climb) — re-emit to avoid limb holes
	return swept and elapsed_ms >= CubeSphere.SHELL_FALL_REEMIT_MS

## COSMOS-ORBITAL-SHELL S1 (§3): commit a new emit axis/cap and schedule the deferred re-emit (the warm + async
## build + single swap are the shipped pipeline; only _pending + the axis/cap snapshot change here).
func _shell_snapshot(dir: Array, cap_cos: float, theta_h: float, floored: bool) -> void:
	_emit_axis = dir
	_emit_cos = cap_cos
	_emit_dir_last = dir
	_emit_thetah_last = theta_h
	_emit_floored_last = floored
	_pending = true
	_snapshot_count += 1                                       # FIX A2 diagnostic: a scheduled re-emit (flat during a held fall)

## COSMOS-ORBITAL-SHELL S2 (§4): the one-shot whole-planet coarse-cache warm. After SHELL_PREWARM_DWELL_S sustained
## off-surface, fill the SHIPPED _pos_cache/_col_cache for every uncached facet under the existing WARM_BUDGET_MS
## per frame, advancing a cursor across all 6·K² fids exactly once per session — so an orbital re-emit over a
## never-visited longitude is a pure cached emit (no warm lag). NEVER-OOM: it fills only the fid-keyed coarse caches
## the ring already uses (hard cap 6·K² ≈ 2.4 MB), never a parallel store; the cursor makes it strictly one-shot and
## the byte ceiling is reachable today on foot. Skipped while a worker reads the caches (_async_building) — same
## quiescence contract as force_rebuild. No-op unless FP_SHELL_PREWARM (⇒ flag-off _process is byte-identical).
func _prewarm_step(dt: float) -> void:
	if not CubeSphere.FP_SHELL_PREWARM:
		return
	# FP_ENV_WARM_ASYNC: the one-shot whole-planet warm fills the SAME _pos_cache the worker now builds off-thread. On
	# the main thread each env facet is ~16 ms, so this prewarm is exactly the second half of the orbit main-thread
	# stall — let the worker fill caches on demand (bounded batch/cycle) instead. No-op on the surface (offsurface false).
	if _env_warm_async_on():
		return
	var total := FacetAtlas.K * FacetAtlas.K * 6
	if _prewarm_cursor >= total:
		return                                # done this session (one-shot)
	if not _offsurface:
		_offsurface_dwell = 0.0
		return
	_offsurface_dwell += dt
	if _offsurface_dwell < CubeSphere.SHELL_PREWARM_DWELL_S:
		return
	if _async_building:
		return                                # a worker is reading the caches — resume next frame (quiescence)
	if _prewarm_cursor < 0:
		_prewarm_cursor = 0
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	while _prewarm_cursor < total:
		if not _pos_cache.has(_prewarm_cursor):
			_ensure_cached(_prewarm_cursor)
		_prewarm_cursor += 1
		if Time.get_ticks_usec() - t0 > budget_us:
			return                            # budget spent — resume next frame

## COSMOS FP-FIXED-FRAME re-anchor (§3): slide the absolute ring mesh by −A in lockstep with PlanetRoot + the
## ActiveFrame so the whole rendered planet stays continuous through a floating-origin shift. The offset survives a
## crossing (set_active re-applies _placement_xform, which now folds it in). No-op unless the fixed frame is on.
func shift_anchor(a: Vector3) -> void:
	if not (CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL):
		return
	_anchor_offset += a
	transform = _placement_xform()

## COSMOS FP-R0 SPIKE: hide these facets' flat quads (they are drawn as real rotated voxel terrains instead).
## Called only behind CubeSphere.FP_R0; on the shipped build nothing calls this so `_excluded` stays empty and the
## ring is byte-identical. Synchronous (a one-time spawn-setup call), unlike a crossing's deferred re-emit.
func set_excluded(fids: Array) -> void:
	_excluded.clear()
	for f in fids:
		_excluded[int(f)] = true
	force_rebuild()

## FP-M1c (docs/COSMOS-FP-M1-DESIGN.md §4.1): set the excluded flat-quad facets to the live neighbour pool and
## rebuild DEFERRED (budgeted _process) rather than synchronously — a pool spawn/retire/crossing must never pay a
## full ring regen on its own frame (§12.1c). No-op re-sets that leave the set unchanged skip the pending flag.
func set_pool_excluded(fids: Array) -> void:
	var next := {}
	for f in fids:
		next[int(f)] = true
	if next == _excluded:
		return
	_excluded = next
	_recompute_sticky()   # TIER-DEPTH P1: fold the new pool set into the sticky backstop (no-op with the flag off)
	_pending = true   # deferred rebuild (the crossing's set_active already re-placed the mesh rigidly)

## FP-S1(d): drive the deferred rebuild off the crossing frame. Cache-warm the newly-front-hemisphere facets under a
## per-frame ms budget; once they are all cached, do the single re-emit. Only active while a crossing is pending.
## COSMOS-PERF STEP 2: first drain any finished off-thread build (swap it in on the main thread). A new crossing that
## arrives while a build is in flight keeps _pending set but does NOT re-dispatch (_async_building gate) — it is served
## once the in-flight build lands, so the worker's read-only cache snapshot is never mutated under it.
# REVISION 7 warmup diagnosis: per-frame ms in the smooth DRIVER (_smooth_drive incl. request+step), the smooth
# tier's step() alone, and the env converge-emit — the three uninstrumented main-thread costs the warmup proc
# breakdown (vt/tex/commit/phys all 0 during fill) points at. Surfaced in telemetry to pinpoint the real bottleneck.
var _dbg_drive_ms := 0.0
var _dbg_step_ms := 0.0
var _dbg_env_ms := 0.0

func _process(_dt: float) -> void:
	_poll_async_rebuild()
	if _smooth != null:
		var _t_drv := Time.get_ticks_usec()
		_smooth_drive()   # FP_FAR_SMOOTH (P1): worker-baked smooth REPLACEMENT ladder for the visible hemisphere (runs every frame)
		_dbg_drive_ms = (Time.get_ticks_usec() - _t_drv) / 1000.0
	# docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): reap builds/evictions + commit the ONE annulus
	# mesh if anything changed. Cheap at rest (fast no-op scans). No-op / null with the flag off.
	if _smooth_v2 != null:
		_smooth_v2.step()
	# COSMOS TEXTURED-LOD U2 (FP_FARRING_CULL_COVERED): re-probe near-coverage on the CULL_REAP_MS cadence and advance the
	# per-cell cull hysteresis; a mask flip sets `_pending` so the active emit path below re-draws (culled cells dropped,
	# uncovered cells restored). No-op / no allocation with the flag off (byte-identical) — runs before the emit branches
	# so THIS frame's rebuild honours the fresh mask.
	_cull_update()
	# FP_BOOT_ASYNC: while the initial hemisphere cache is still filling, warm the next budgeted batch + progressive re-emit,
	# then return — the boot warm owns the ring until the front is fully cached (it then restores the shipped paths below).
	# A crossing during boot-warm still renders: set_active re-places the absolute mesh rigidly; its deferred exclusion
	# re-emit is served by the shipped _pending path once boot-warm completes. Off ⇒ never entered (byte-identical).
	if CubeSphere.FP_BOOT_ASYNC and _boot_warm:
		# Round 4: hold the warm off the prewarm/compile critical path until essential-ready opens the gate (or the
		# wall-clock failsafe trips). Until then only the synchronous seed is drawn — the far side does not contend
		# with the shader-compile frames.
		if not _boot_gate_open and Time.get_ticks_msec() - _boot_setup_ms >= BOOT_GATE_FAILSAFE_MS:
			_boot_gate_open = true
		if _boot_gate_open:
			_boot_warm_step()
		return
	_prewarm_step(_dt)               # COSMOS-ORBITAL-SHELL S2: one-shot whole-planet warm (no-op unless FP_SHELL_PREWARM + off-surface)
	if _async_building:
		return
	# COSMOS-ORBITAL-SHELL S1: the emit cull axis + threshold — ĉ + cos(θ_emit) when the camera-set law is engaged,
	# else the shipped active-facet normal + BACK_CULL (byte-identical). Both _warm_front and the rebuild's
	# visible_fids() consume THIS pair, so the warmed set and the emitted set can never disagree.
	var p := _cull_params()
	# NO-PROTRUSION FIDELITY §1 F2 (FP_MID_DENSE): refresh the ring-2 dense-promotion disc for the current emit axis and
	# reap any promotion that left it (bounded _bpos_cache). Here — past the `_async_building` guard (worker idle, safe to
	# erase caches), before the warm/emit below so this frame's warm builds/dispatches the freshly-promoted set. No-op off.
	_recompute_mid_dense(p)
	# COSMOS FAR-CRUISE NEVER-BLACK: guarantee the sub-camera (active) facet paints an opaque backstop with NO warm-lag
	# black and NO sunk well where the near field is absent. Past the _async_building guard (safe to touch caches), before
	# the regime branches so THIS frame's emit honours it. No-op with the flag off / off-surface (byte-identical).
	_noblack_guarantee(p)
	# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 (FP_FARRING_UNCOVERED_TRUE): the un-sink PATTERN depends only on the
	# player's column, so re-arm `_pending` only once it has drifted ≥ UNSINK_DRIFT_BLOCKS since the last arm — not
	# every frame (the idle short-circuits below still hold in between). No-op with the flag off (byte-identical).
	_unsink_drift_check()
	if _shell_orbit():
		# COSMOS-PERF FALL-COLLAPSE FIX A (FP_SHELL_ORBIT_IDLE): idle short-circuit — once the front is fully warmed AND
		# emitted with nothing pending, skip the per-frame full 6·K² _warm_front scan (the ~67 ms airborne proc baseline)
		# until the next drift snapshot re-sets `_pending`. Mirrors the surface `_srf_converged` gate. Off ⇒ the scan runs
		# every frame exactly as today (byte-identical). The next drift (shell_set_camera_abs) clears it via `_pending`.
		if CubeSphere.FP_SHELL_ORBIT_IDLE and not _pending and _orbit_converged:
			return
		# FP_ENV_WARM_ASYNC: relocate the heavy env-cache build off the main thread. Instead of warming ~1 x 16 ms env
		# facet per frame on the main thread (the 51 ms orbit stall), dispatch a worker that warms a bounded batch and
		# emits the ready subset; the main thread only pays the cheap swap. Byte-identical heights (same builder) ⇒ the
		# no-protrusion gate is unmoved. Scoped to env_all + orbit + async; off ⇒ the shipped S1b path below runs verbatim.
		if _env_warm_async_on():
			_orbit_warm_async(p)
			return
		# COSMOS-ORBITAL-SHELL S1b (§3): TRUE ORBIT — progressive cached-subset emit. Never block the whole rebuild on
		# the ~1900-facet cap being cached in ONE frame (impossible under web ×25 warm cost → the live far-side stall).
		# Warm cumulatively under budget, emit the cache-ready subset now, re-emit as coverage grows (throttled by
		# SHELL_REEMIT_GROWTH). The async worker still reads only cache-ready facets (visible_fids cache-filters here).
		var done := _warm_front_step(p[0], p[1])
		if done:
			_warm_pass_count += 1
		else:
			_warm_fail_count += 1
		var sz := _pos_cache.size() + _bpos_cache.size()
		# Re-emit: on a fresh drift/engage (_pending); every SHELL_REEMIT_GROWTH newly-cached facets WHILE still filling
		# the front cap (progressive reveal); and ONCE when the front cap just finished caching (done ↑) to capture the
		# tail. Once done, the growth trigger is gated off so background prewarm back-filling never churns re-emits.
		var grew := (not done) and (sz - _last_emit_cache_size) >= CubeSphere.SHELL_REEMIT_GROWTH
		# FIX A2 (FP_SHELL_FALL_HOLD): a `_pending` (a genuine, now-throttled snapshot) or a floor-tail (done↑) re-emits
		# immediately; the PROGRESSIVE `grew` re-emit is throttled to ≤ 1/SHELL_FALL_REEMIT_MS so a cap that can't fully
		# warm within budget on web (done never true) cannot fire a SYNCHRONOUS _rebuild_full every few frames (the spikes).
		var grew_ok := grew
		if CubeSphere.FP_SHELL_FALL_HOLD and grew and not _pending:
			grew_ok = Time.get_ticks_msec() - _last_rebuild_ms >= CubeSphere.SHELL_FALL_REEMIT_MS
		if _pending or grew_ok or (done and not _was_done):
			_last_emit_cache_size = sz
			_emit_cached_only = true
			_begin_rebuild()
			_last_rebuild_ms = Time.get_ticks_msec()
		_was_done = done
		# FIX A: converged once the front is fully warmed AND the pending emit has been consumed (async clears _pending
		# in _dispatch_async_rebuild). The next drift snapshot re-sets _pending, which the top-of-branch gate honours.
		_orbit_converged = done and not _pending
	elif TierPlace.warm_converge_on():
		# TIER-DEPTH warm-converge: the SURFACE path adopts the progressive discipline so a stale un-sunk backstop quad
		# never lingers over live near meshes while the dense caches warm (the over-near strip / sh_wfail thrash).
		var _t_env := Time.get_ticks_usec()
		_surface_converge_emit(p)
		_dbg_env_ms = (Time.get_ticks_usec() - _t_env) / 1000.0
	else:
		# SURFACE (floored) / shipped: the all-or-nothing warm gate (byte-identical; the worker never sees an uncached facet).
		if not _pending:
			return
		_emit_cached_only = false
		if _warm_front_step(p[0], p[1]):   # all front-hemisphere facets cached → safe to re-emit this frame
			_warm_pass_count += 1
			_begin_rebuild()
		else:
			_warm_fail_count += 1

## COSMOS TIER-DEPTH-PRIORITY warm-converge (FP_TIER_WARM_CONVERGE, §5.3 / §7 P1): the SURFACE progressive-emit driver
## that replaces the all-or-nothing warm gate. Warm cumulatively under WARM_BUDGET_MS, then emit the cache-ready subset
## (visible_fids(true) filters an uncached backstop OUT — it is never drawn as a stale un-sunk quad), re-emitting the
## MOMENT a new dense backstop cache lands so a just-entered pool facet flips to SUNK the frame it is ready (kills the
## over-near strip); far-horizon coarse growth batches at SHELL_REEMIT_GROWTH (its transient holes sit behind the near
## disk). Idle short-circuit preserves the shipped zero-cost steady state: once the whole front is cached AND emitted
## (`_srf_converged`) it does no work until the next role-event (`_pending`). `p` = [cull axis, cos threshold] (shipped
## active-facet law on the surface). Bounded re-emits (≤ backstop count) + scalar state ⇒ NEVER-OOM.
## FP_ENV_FALL_HOLD: WorldManager sets this while the player descends fast. Plain state write (no work here).
func set_fall_hold(v: bool) -> void:
	_fall_hold = v

## REVISION 5 (G-FS-QUIESCE-SURF): `quiesce_on`/`demand_on`/`fallback_on`/`floored_async_on`/`warm_split_on` override
## FP_RING_QUIESCE/FP_ENV_DEMAND_DISC/FP_ENV_FALLBACK_EMIT/FP_ENV_FLOORED_ASYNC/FP_WARM_EMIT_SPLIT (the codebase's
## gate-forcing convention) and `force_async`/`env_on` are threaded straight into `_env_async_floored_on` so a
## headless gate can drive the LIVE floored counting/dispatch law without a compile-time sed of any of the five
## flags or the three consts `TierPlace.env_all_on()` folds together. Every real caller (`_process`) passes no
## override ⇒ every default resolves to the shipped compile const ⇒ byte-identical.
func _surface_converge_emit(p: Array, quiesce_on := CubeSphere.FP_RING_QUIESCE, demand_on := CubeSphere.FP_ENV_DEMAND_DISC, fallback_on := CubeSphere.FP_ENV_FALLBACK_EMIT, floored_async_on := CubeSphere.FP_ENV_FLOORED_ASYNC, warm_split_on := CubeSphere.FP_WARM_EMIT_SPLIT, force_async := false, env_on := TierPlace.env_all_on()) -> void:
	# FP_ENV_FLOORED_ASYNC: on the ground / de-orbit descent, mirror the ORBIT path — the WORKER chord-fills coverage
	# and env-warms a bounded batch/cycle; NO main-thread env build (kills the 16-40ms/facet hitch), no cache race
	# (the worker is the sole writer under `_async_building`). Dispatch until every visible facet is truly enveloped
	# (_count_uncached_visible counts by _benv_done/_env_done). Coverage is structural from dispatch #1 (chord fill).
	if _env_async_floored_on(fallback_on, floored_async_on, force_async, env_on):
		if not _pending and _srf_converged:
			return
		_emit_cached_only = true
		var hold := CubeSphere.FP_ENV_FALL_HOLD and _fall_hold
		var want := _pending or not _orbit_emitted_once
		var converged := false
		if hold:
			# CHORD-ONLY: dispatch only when COVERAGE changes (a visible facet still has no cache) — never for the env
			# upgrade. ONE scan (uncovered); chords keep hole=0, worker does no env, no continuous re-emit. NOT converged
			# (env resumes when the hold lifts). Hoisted below the hold test so the held frame runs a single 6·K² scan.
			if _count_uncovered_visible(p, quiesce_on) > 0: want = true
			if want:
				_begin_rebuild()
				_orbit_emitted_once = true
				_srf_env_dirty = false
			_srf_converged = converged
			return
		var remaining := _count_uncached_visible(p, quiesce_on, demand_on, fallback_on, floored_async_on)
		converged = remaining == 0 and not _pending
		# FP_ENV_RESUME_PACED: throttle the env-upgrade (non-coverage) dispatch so the touchdown resume doesn't burst
		# back-to-back; _pending / first-emit stay immediate above. Off ⇒ every-frame dispatch (byte-identical).
		var env_want := false
		if remaining > 0 and (not CubeSphere.FP_ENV_RESUME_PACED or (Time.get_ticks_msec() - _last_env_dispatch_ms) >= CubeSphere.ENV_RESUME_MS):
			env_want = true
			_last_env_dispatch_ms = Time.get_ticks_msec()
		if want:
			# A genuine coverage dispatch (fresh drift / never-yet-emitted this engage) — always a REAL emit.
			_begin_rebuild()
			_orbit_emitted_once = true
			_srf_env_dirty = false
		elif env_want:
			# REVISION 5 Stage B (FP_WARM_EMIT_SPLIT): the ONLY reason to dispatch is a non-coverage env upgrade —
			# warm the caches WITHOUT touching the mesh; re-emit once, later, when the envelope fully converges
			# (below). Off ⇒ the shipped full re-emit every cycle (byte-identical dispatch cadence).
			if warm_split_on:
				_dispatch_warm_only(demand_on, fallback_on, floored_async_on, env_on)
				_srf_env_dirty = true
			else:
				_begin_rebuild()
				_orbit_emitted_once = true
		elif remaining == 0 and _srf_env_dirty:
			# The env upgrades that warm-only cycles built just converged — emit ONCE so the upgraded heights
			# actually reach the GPU (they were held meanwhile by the ε sink + skirts, matching REV3's T1/T2 "safe
			# to lag a frame" argument).
			_begin_rebuild()
			_orbit_emitted_once = true
			_srf_env_dirty = false
		_srf_converged = converged
		return
	if not _pending and _srf_converged:
		return                                    # steady state — no per-frame warm scan (matches the shipped idle frame)
	_emit_cached_only = true
	var done := _warm_front_step(p[0], p[1])
	if done:
		_warm_pass_count += 1
	else:
		_warm_fail_count += 1
	var b_ready := _bpos_cache.size()             # a grown dense cache == a new sunk backstop ready to replace a stale quad
	var c_ready := _pos_cache.size()
	var back_grew := b_ready > _srf_last_bcache
	var horizon_grew := (c_ready - _srf_last_ccache) >= CubeSphere.SHELL_REEMIT_GROWTH
	if _pending or back_grew or horizon_grew or (done and not _srf_was_done):
		_srf_last_bcache = b_ready
		_srf_last_ccache = c_ready
		_begin_rebuild()                          # emits visible_fids(true) — cache-ready facets only, sunk backstops included
	_srf_was_done = done
	_srf_converged = done                         # fully cached + emitted ⇒ idle until the next role-event re-sets _pending

## COSMOS FAR-CRUISE NEVER-BLACK: on the FLOORED surface, guarantee the sub-camera (active) facet paints an opaque
## backstop with NO warm-lag black gap and NO sunk well where the near field is absent. Runs each non-building frame
## (past the _async_building guard, before the regime branches) so it holds in every surface regime. (a) force a cheap
## dense CHORD into _bpos_cache the instant the active facet's cache is missing — so the cache-filtered emit never drops
## it (kills the BLACK); (b) probe the near field UNDER the camera and, when it is NOT meshed, mark the active facet to
## emit UN-SUNK (true surface); (c) set _pending on any state change / when it is not currently drawn so the emit path
## re-draws it once (then the idle short-circuits hold — no churn). Off / off-surface / no active facet ⇒ inert (byte-
## identical). NEVER-OOM: one facet's existing dense cache + one int, no per-frame alloc, no growth with walk distance.
## `noblack_on`/`quiesce_on` override FP_FARRING_ACTIVE_NOBLACK∧FP_FARRING_FULL_COVER / FP_RING_QUIESCE (mirrors the
## codebase's gate-forcing convention) so a headless gate can drive the REAL never-black re-arm logic without a
## compile-time sed of either flag pair. Every real caller (`_process`) passes no override ⇒ both compile-time
## consts govern exactly as shipped (byte-identical).
func _noblack_guarantee(p: Array, quiesce_on := CubeSphere.FP_RING_QUIESCE, noblack_on := CubeSphere.FP_FARRING_ACTIVE_NOBLACK and CubeSphere.FP_FARRING_FULL_COVER) -> void:
	if not noblack_on:
		return
	if _shell_orbit() or _active_fid < 0:
		_noblack_unsink_fid = -1
		return
	# Only guarantee when the active facet is genuinely in the emitted front (it always is on the floored surface —
	# _front_visible forces it — but stay defensive against a degenerate cull axis).
	if not _front_visible(_active_fid, p[0], p[1]):
		_noblack_unsink_fid = -1
		return
	var fid := _active_fid
	# REVISION 4 Stage B (FP_RING_QUIESCE, R4.2): a smooth-covered active facet is drawn by its OWN committed S2
	# tile — that IS the never-black cover (strictly better than the sunk shell backstop this guarantee otherwise
	# builds). It is PERMANENTLY excluded from the shell's emit set (`visible_fids()`'s `_smooth_covered` check), so
	# `_emitted.has(fid)` can never become true for it — the shipped `not _emitted.has(fid)` disjunct below re-arms
	# `_pending` EVERY frame for as long as it stays smooth-covered (the endless re-emit train R4.2 root-caused).
	# Skip the chord build + the unsink probe too (neither is needed while the tile covers). Off ⇒ `covered` is
	# always false (byte-identical to the shipped guarantee).
	var covered := quiesce_on and _smooth_covered(fid)
	# (a) IMMEDIATE cache — never wait for the per-frame warm to reach the sub-camera facet. A missing cache is dropped
	# from the cache-filtered emit set (visible_fids(true) / _emit_cache_ready) → the initial BLACK. A dense chord is
	# cheap (~289 profile samples, one facet) and gives full coverage NOW; the normal warm upgrades it to the envelope.
	var built_now := false
	if not covered and not _bpos_cache.has(fid):
		_ensure_backstop_chord_cached(fid)
		built_now = true
	# (b) un-sink WHERE the near field is genuinely absent under the camera (probe the SAME coverage callable U2 uses).
	var new_unsink := _noblack_unsink_fid
	if not covered:
		var uncovered := not _noblack_near_meshed(fid)
		new_unsink = fid if uncovered else -1
	# (c) re-emit once on any change or if the active facet is not currently drawn (and not smooth-covered); then the
	# idle short-circuits hold.
	if built_now or new_unsink != _noblack_unsink_fid or (not _emitted.has(fid) and not covered):
		_pending = true
	_noblack_unsink_fid = new_unsink

## COSMOS FAR-CRUISE NEVER-BLACK: is the near voxel field actually meshed in a TIGHT column UNDER THE CAMERA on the
## active facet? Uses the SAME (fid, fid-lattice AABB) → module_world.skin_near_meshed (godot_voxel is_area_meshed)
## callable the U2 cull uses. An INVALID callable (GDScript / no-module path) ⇒ assume COVERED (keep the shipped SUNK
## backstop — never worse than today). The probe point is the sub-camera surface point under the camera-set axis (else
## the facet centre) mapped into the facet's own lattice — the frame is_area_meshed operates in (as skin_near_meshed
## documents). Main thread only (reads the live _emit_axis / _cull_cover_query).
func _noblack_near_meshed(fid: int) -> bool:
	if not _cull_cover_query.is_valid():
		return true
	var dir: Array
	if _cam_set and (_emit_axis[0] != 0.0 or _emit_axis[1] != 0.0 or _emit_axis[2] != 0.0):
		dir = _emit_axis                                 # ABSOLUTE sub-camera direction (under the player)
	else:
		dir = _facet_centre_dir(fid)                     # fallback: the facet centre (no camera-set axis maintained)
	var r := FacetAtlas.R_BLOCKS
	var l: Array = FacetAtlas.world_to_lattice64(fid, dir[0] * r, dir[1] * r, dir[2] * r)
	var h := CubeSphere.NOBLACK_PROBE_HALF
	var yh := CubeSphere.NOBLACK_PROBE_YHALF
	var aabb := AABB(Vector3(float(l[0]) - h, float(l[1]) - yh, float(l[2]) - h), Vector3(2.0 * h, 2.0 * yh, 2.0 * h))
	return bool(_cull_cover_query.call(fid, aabb))

## COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1/§4 (FP_FARRING_UNCOVERED_TRUE): re-arm `_pending` once the player's
## column has drifted ≥ UNSINK_DRIFT_BLOCKS since the last arm (or on the very first real column) — the un-sink
## PATTERN is a pure function of the column alone, so it need not re-run every frame. `on` overrides the compile
## const (mirrors `_noblack_guarantee`'s `noblack_on` param) so a headless gate can drive the real re-arm law
## without sed. Off / no real column yet ⇒ inert (byte-identical).
func _unsink_drift_check(on := CubeSphere.FP_FARRING_UNCOVERED_TRUE) -> void:
	if not on or not _unsink_have_col:
		return
	if not _unsink_armed or _player_col_abs.distance_to(_unsink_armed_col) >= CubeSphere.UNSINK_DRIFT_BLOCKS:
		_unsink_armed_col = _player_col_abs
		_unsink_armed = true
		_pending = true

## COSMOS-ORBITAL-SHELL S1 (§3): the current emit cull axis + cos-threshold. With the camera-set law engaged
## (FP_SHELL_CAMERA_SET, driver called) it is [ĉ_abs, cos(θ_emit)]; otherwise the SHIPPED [active-facet normal,
## BACK_CULL] — so with the flag off the emitted set is computed exactly as today (byte-identical), and on the
## floored surface (θ_emit ≥ 90° ⇒ cos ≈ BACK_CULL) it differs from the active-facet law only in facets behind
## the limb (byte-visually identical). Called on the main thread only (the async worker snapshots visible_fids()).
func _cull_params() -> Array:
	if _cam_set:
		return [_emit_axis, _emit_cos]
	return [FacetAtlas.facet_normal64(_active_fid), BACK_CULL]

## COSMOS-ORBITAL-SHELL (live fix 2026-07-19): the TRUE-ORBIT regime — the camera-set law engaged AND off-surface
## (not floored). Off-surface there is NO near voxel field over the ground under the camera (the near disk sits at
## the player's FLIGHT altitude, hundreds of blocks up, not on the ground), so the "backstop" role (sunk, meant to
## hide BEHIND near voxels) and the active/`_excluded` EXCLUSION (near voxels own that facet) are both WRONG here:
## they leave a HOLE at the sub-camera facet that SWEEPS as the active facet churns (~1 facet / 3 frames in orbit) —
## the live "facets under me disappear" flicker. In this regime the shell OWNS the sub-camera facet, drawn as a
## regular coarse facet from the prewarm-filled coarse cache (always ready ⇒ no warm hole; un-sunk ⇒ true surface).
## Byte-identical off (flag off ⇒ `_cam_set` false) and on the surface (floored ⇒ shipped exclusion / backstop).
func _shell_orbit() -> bool:
	return _cam_set and not _emit_floored_last

## FP_ENV_WARM_ASYNC: is the env-cache build relocated to the far-ring worker? Requires the flag, the env_all regime
## (the only path whose ~16 ms/facet EDGE-CANON build blows the warm budget), the ORBIT regime (where the whole planet
## is drawn coarse ⇒ the main-thread warm burst), and a real worker to build on. Off in any of those ⇒ the shipped
## main-thread warm runs verbatim (byte-identical). Read on the main thread; snapshotted into `_async_env_warm` at dispatch.
func _env_warm_async_on() -> bool:
	return CubeSphere.FP_ENV_WARM_ASYNC and TierPlace.env_all_on() and _shell_orbit() and _async_enabled()

## FP_ENV_FLOORED_ASYNC: the FLOORED/descent twin of _env_warm_async_on — relocate the env warm to the worker (and
## draw chord fallbacks meanwhile) on the ground / during de-orbit (NOT _shell_orbit). Requires the fallback machinery
## (FP_ENV_FALLBACK_EMIT) + env_all + a real worker. The camera-set law drives the floored emit here (_cam_set), so
## this is scoped to the camera-set floored regime — the pure-walk surface without the shell law keeps the shipped
## main-thread warm (byte-identical). Off in any requirement ⇒ false ⇒ the shipped floored warm runs verbatim.
## REVISION 5 (G-FS-QUIESCE-SURF): `fallback_on`/`floored_async_on` override FP_ENV_FALLBACK_EMIT/FP_ENV_FLOORED_ASYNC
## (mirrors the codebase's gate-forcing convention), `env_on` overrides `TierPlace.env_all_on()` (that static reads
## THREE compile consts with no override of its own — this param lets a gate force the regime without sed-ing all
## three), and `force_async` skips the `_async_enabled()` hardware/flag check (a headless gate's regime selection
## should not depend on core count or FP_FARRING_ASYNC_REBUILD, a DIFFERENT flag). Every real caller passes no
## override ⇒ byte-identical to the shipped check.
func _env_async_floored_on(fallback_on := CubeSphere.FP_ENV_FALLBACK_EMIT, floored_async_on := CubeSphere.FP_ENV_FLOORED_ASYNC, force_async := false, env_on := TierPlace.env_all_on()) -> bool:
	return floored_async_on and fallback_on \
		and env_on and _cam_set and _emit_floored_last and (force_async or _async_enabled())

## Either regime warms env on the worker (+ chord fallback on emit). Used to snapshot `_async_env_warm` at dispatch.
func _env_async_any() -> bool:
	return _env_warm_async_on() or _env_async_floored_on()

## FP_ENV_WARM_ASYNC: the ORBIT driver when the env build lives on the worker. No main-thread warm at all — a cheap
## dot-scan counts uncached visible facets, then (when the worker is idle: _process guards this behind `not _async_building`)
## a worker dispatch warms a bounded batch + emits the ready subset. Re-dispatched each idle frame until the front is
## fully cached (`remaining == 0`), then idles like the shipped `_orbit_converged` short-circuit. The reveal grows
## ENV_WARM_BATCH facets per worker cycle — same total work as the shipped warm, but entirely off the frame budget.
## `quiesce_on` overrides FP_RING_QUIESCE (mirrors the codebase's gate-forcing convention — `on := CubeSphere.FLAG`
## params on `_apply_slot_indirect`/`build_tile`/etc.) so a headless gate can drive the fix without a compile-time
## sed; every real caller passes no override ⇒ the compile-time const governs (byte-identical, this param exists
## purely for G-FS-QUIESCE-RING's falsify/fix scenarios in ONE gate run).
func _orbit_warm_async(p: Array, quiesce_on := CubeSphere.FP_RING_QUIESCE) -> void:
	_emit_cached_only = true
	# REVISION 5 Stage A (FP_ENV_DEMAND_DISC): ORBIT keeps its existing law UNCHANGED — off-surface the whole coarse
	# hemisphere IS the drawn surface (no "near field on the ground" concept to bound the envelope demand against),
	# so `demand_on` is forced false here regardless of the global flag.
	var remaining := _count_uncached_visible(p, quiesce_on, false)
	# Dispatch when: a fresh drift/engage (`_pending`), any facet still to warm (progressive reveal), or the mesh has
	# never been emitted this engage (fill it even at 0 growth). Each dispatch's worker warms the next batch off-thread.
	# FP_ENV_FALL_HOLD: falling fast ⇒ chord-only, dispatch only when COVERAGE changes (uncovered visible facet), never
	# for env upgrade — calms the >384 band's worst frames while chords keep coverage. Off ⇒ shipped remaining>0.
	var want := _pending or not _orbit_emitted_once
	if CubeSphere.FP_ENV_FALL_HOLD and _fall_hold:
		if _count_uncovered_visible(p, quiesce_on) > 0: want = true
	elif remaining > 0:
		want = true
	if want:
		_begin_rebuild()
		_orbit_emitted_once = true
	# Converged once every visible facet is cached AND the pending emit was consumed — the next drift re-sets `_pending`.
	_orbit_converged = remaining == 0 and not _pending

## FP_ENV_WARM_ASYNC: how many front-hemisphere facets still lack their emit cache. Cheap (front-cull dot + a dict
## `has()` per fid — NO profile sampling), so it is safe to run every idle frame. Mirrors visible_fids' cull + role.
## `quiesce_on` overrides FP_RING_QUIESCE — see `_orbit_warm_async`'s note (gate-forcing param, byte-identical for
## every real caller, which passes no override). REVISION 5 Stage A adds `demand_on`/`fallback_on`/`floored_async_on`
## — override params for FP_ENV_DEMAND_DISC/FP_ENV_FALLBACK_EMIT/FP_ENV_FLOORED_ASYNC, same convention, so a headless
## gate can drive the LIVE counting law without a const sed; every real caller passes at most `quiesce_on` (the other
## three default to their compile consts) ⇒ byte-identical.
func _count_uncached_visible(p: Array, quiesce_on := CubeSphere.FP_RING_QUIESCE, demand_on := CubeSphere.FP_ENV_DEMAND_DISC, fallback_on := CubeSphere.FP_ENV_FALLBACK_EMIT, floored_async_on := CubeSphere.FP_ENV_FLOORED_ASYNC) -> int:
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var k := FacetAtlas.K
	var cnt := 0
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# REVISION 4 Stage B (FP_RING_QUIESCE, R4.2): a smooth-covered facet is never in the shell's emit set
				# (visible_fids' `_smooth_covered` exclusion) — counting it here as "still needs a cache" is exactly
				# why `remaining` never reached 0 and the env convergence latch never engaged. Off ⇒ counted as shipped.
				if quiesce_on and _smooth_covered(fid):
					continue
				if _dense_warm(fid):   # FP_MID_DENSE: a mid-dense target still needs its dense cache (keeps orbit dispatching)
					# FP_ENV_FLOORED_ASYNC: a dense CHORD present but not yet enveloped still needs warming — count by
					# `_benv_done` so the floored warm keeps dispatching to full dense-env convergence.
					if not (_benv_done.has(fid) if floored_async_on else _bpos_cache.has(fid)):
						cnt += 1
				# REVISION 5 Stage A (FP_ENV_DEMAND_DISC): outside the near-field bound (no dense/mid-dense role AND
				# not within ENV_DEMAND_RINGS of the emit axis), the coarse CHORD is the correct TERMINAL state — count
				# it done the instant a chord exists, never demand the ~300×-heavier envelope for it. Off ⇒ falls
				# through to the shipped env_done test below (every coarse facet upgrades).
				elif demand_on and not _in_env_demand_disc(fid, nrm):
					if not _pos_cache.has(fid):
						cnt += 1
				# FP_ENV_FALLBACK_EMIT: a chord fallback present but NOT yet enveloped still needs warming — count by
				# `_env_done`, so `remaining` keeps dispatching until FULL env convergence (not just chord coverage).
				elif not (_env_done.has(fid) if fallback_on else _pos_cache.has(fid)):
					cnt += 1
	return cnt

## FP_ENV_FALL_HOLD: how many visible facets have NO cache AT ALL (not even a chord) — i.e. a real COVERAGE gap, as
## opposed to _count_uncached_visible's "not yet ENVELOPED". While the fall-hold is active the driver dispatches
## (chord-only) exactly when this is > 0, so the transition reveal is chord-filled (hole=0) without the continuous
## env re-emit churn. A chord counts as covered. Same cheap dot-cull + dict-has as _count_uncached_visible.
## `quiesce_on` overrides FP_RING_QUIESCE — see `_orbit_warm_async`'s note.
func _count_uncovered_visible(p: Array, quiesce_on := CubeSphere.FP_RING_QUIESCE) -> int:
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var k := FacetAtlas.K
	var cnt := 0
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# REVISION 4 Stage B (FP_RING_QUIESCE, R4.2): mirrors _count_uncached_visible's exclusion above — a
				# smooth-covered facet is served by its tile, not the shell, so it must not hold `remaining` above 0.
				if quiesce_on and _smooth_covered(fid):
					continue
				if _dense_warm(fid):
					if not _bpos_cache.has(fid):
						cnt += 1
				elif not _pos_cache.has(fid):
					cnt += 1
	return cnt

## FP_ENV_WARM_ASYNC: is facet `fid`'s emit cache present, given its FROZEN backstop role? (worker-thread reader —
## uses the snapshot dict, never live `_is_backstop`, so it never races set_pool_excluded).
func _worker_cache_ready(fid: int) -> bool:
	if _async_backstop.has(fid):
		return _bpos_cache.has(fid)
	return _pos_cache.has(fid)

## COSMOS-PERF STEP 2: whether the off-main-thread rebuild path is live (flag on AND real background workers exist —
## a single-core build has no worker to flip is_task_completed, so it must fall back to the synchronous rebuild).
func _async_enabled() -> bool:
	return CubeSphere.FP_FARRING_ASYNC_REBUILD and OS.get_processor_count() > 1

## Complete a warmed pending rebuild: dispatch it to a worker (async path) or build it inline (synchronous fallback).
func _begin_rebuild() -> void:
	_begin_rebuild_count += 1        # S1b telemetry: prove the emit actually runs post-engage (0 ⇒ warm-gate stall)
	if _async_enabled():
		_dispatch_async_rebuild()
	else:
		_rebuild_full()

## MAIN THREAD: snapshot the (already-warmed) visible set and hand the whole mesh-DATA build to a worker. The caches the
## worker reads are frozen for its lifetime — _process will not warm/dispatch again while _async_building (the gate in
## _process), and force_rebuild/set_excluded join first — so the worker only ever READS _pos_cache/_col_cache.
func _dispatch_async_rebuild() -> void:
	transform = _placement_xform()   # rigid re-place is cheap + main-thread-only (same as _rebuild_full's first line)
	_refresh_slot_snapshot()         # COSMOS LOD-TEXTURE Phase 4: freeze the slot map on MAIN before the worker reads it (no-op off)
	# FP_ENV_WARM_ASYNC: when the worker builds its OWN env caches, hand it the FULL front set (uncached included) so it
	# can warm a bounded batch and emit them the same cycle. Frozen here so the worker's warm/emit is stable for its run
	# (main will not touch the caches while _async_building). Off ⇒ the shipped cache-filtered set (byte-identical).
	_async_env_warm = _env_async_any()
	_async_floored = _env_async_floored_on()   # FP_ENV_FLOORED_ASYNC: frozen regime — floored dense targets emit sunk
	_async_chord_only = CubeSphere.FP_ENV_FALL_HOLD and _fall_hold   # chord-only while falling fast (coverage, no env)
	# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §4 (FP_FARRING_UNCOVERED_TRUE): freeze the player column the worker's
	# `_emit_cached(..., from_worker=true)` un-sink test reads — the SAME `_async_backstop` freeze contract (never
	# read the live, main-thread-mutated `_player_col_abs`/`_unsink_have_col` off-thread). Cheap unconditional copy
	# (a Vector3 + a bool); with the flag off it is frozen but never read (byte-identical).
	_async_unsink_col = _player_col_abs
	_async_unsink_have_col = _unsink_have_col
	# REVISION 5 Stage A (FP_ENV_DEMAND_DISC): frozen for the worker's "have" test. ORBIT keeps its existing law
	# unchanged (no near field to bound the envelope demand against off-surface), so force it off there.
	_async_demand_on = CubeSphere.FP_ENV_DEMAND_DISC and not _shell_orbit()
	_async_demand_axis = _cull_params()[0] if _async_demand_on else [0.0, 0.0, 1.0]
	_async_warm_only = false   # a full emit dispatch — the worker builds the mesh (never the warm-only cache-fill mode)
	# REVISION 3 T2 (FP_SHELL_SNAP_GEN): bump the snapshot generation BEFORE taking visible_fids() below and freeze
	# which gen THIS in-flight build used (`_async_snap_gen`, read back by `_swap_in_arrays` on commit) — off ⇒ both
	# stay 0 (dead reads, `_mesh_inc_gate` uses the shipped `_shell_gen`-at-mark law instead).
	if CubeSphere.FP_SHELL_SNAP_GEN:
		_snap_gen += 1
	_async_snap_gen = _snap_gen
	# S1b: in the true-orbit progressive path _emit_cached_only filters to cache-ready facets, so the worker (which reads
	# _pos_cache/_bpos_cache) never touches an uncached facet; every other path passes false ⇒ the shipped full front set.
	_async_fids = visible_fids(false) if _async_env_warm else visible_fids(_emit_cached_only)
	_refresh_limb_set(_async_fids)   # COSMOS PLANET-VIEW §3 (B): freeze the silhouette-ring set on MAIN before the worker reads it (no-op off)
	# COSMOS far-ring full coverage (§4): freeze the DENSE-TARGET role on the MAIN thread so the worker never reads
	# `_excluded` live (set_pool_excluded may mutate it mid-run). `_async_backstop` = backstop ∪ mid-dense disc (the
	# facets the worker warms + emits dense); `_async_mid` = the mid-dense-only subset (drawn COARSE as a fallback until
	# its dense cache is warmed). Only populated under FULL_COVER; empty otherwise → worker sinks nothing (byte-identical).
	_async_backstop = {}
	_async_mid = {}
	if CubeSphere.FP_FARRING_FULL_COVER:
		for fid in _async_fids:
			if _dense_warm(fid):
				_async_backstop[fid] = true
				if _is_mid_dense(fid):
					_async_mid[fid] = true
	# V2-3b (FP_SMOOTH_V2_EXCL_BLKLOD): freeze which of THIS build's facets `_smooth_v2` already has resident, on
	# MAIN, before the worker reads it — `is_resident()` is a plain Dictionary lookup, safe to call here (main
	# thread) but never off-thread. Off / no `_smooth_v2` ⇒ stays empty (byte-identical worker emit).
	_async_v2_resident = {}
	if CubeSphere.FP_SMOOTH_V2_EXCL_BLKLOD and CubeSphere.FP_BLOCKY_FARRING and _smooth_v2 != null:
		for fid in _async_fids:
			if _smooth_v2.is_resident(int(fid)):
				_async_v2_resident[int(fid)] = true
	_async_arrays = []
	_pending = false                 # consumed — a fresh crossing sets it again and is served after this build lands
	_async_building = true
	_async_task_id = WorkerThreadPool.add_task(Callable(self, "_async_build_worker"), false, "far-ring mesh rebuild")

## REVISION 5 Stage B (FP_WARM_EMIT_SPLIT): dispatch a WARM-ONLY cycle — fills up to ENV_WARM_BATCH missing env
## caches, never touches the mesh. Called from `_surface_converge_emit` exactly when the ONLY reason to dispatch is
## a non-coverage env upgrade (coverage dispatches always go through the real `_begin_rebuild()`/`_dispatch_async_rebuild`
## path above). Mirrors that function's freeze-then-dispatch shape: a REAL WorkerThreadPool task when one is usable
## (`_async_enabled()`), else a SYNCHRONOUS stand-in that runs the identical `_run_env_warm_pass` inline — this is
## also exactly what a headless gate exercises (no worker/thread required to prove the counting law converges).
func _dispatch_warm_only(demand_on: bool, fallback_on: bool, floored_on: bool, env_on: bool) -> void:
	_begin_rebuild_count += 1   # S1b telemetry: a dispatch cycle happened (mirrors _begin_rebuild's own increment)
	_async_floored = floored_on
	_async_demand_on = demand_on
	_async_demand_axis = _cull_params()[0]
	_async_fids = visible_fids(false)
	_async_backstop = {}
	_async_mid = {}
	if CubeSphere.FP_FARRING_FULL_COVER:
		for fid in _async_fids:
			if _dense_warm(fid):
				_async_backstop[fid] = true
				if _is_mid_dense(fid):
					_async_mid[fid] = true
	if _async_enabled():
		_async_env_warm = true
		_async_chord_only = false
		_async_warm_only = true
		_async_arrays = []
		_async_building = true
		_async_task_id = WorkerThreadPool.add_task(Callable(self, "_async_build_worker"), false, "far-ring env warm-only")
	else:
		# Synchronous stand-in (single-core / async rebuild off): run ONE warm cycle inline right now — builds
		# caches only, never touches the mesh. `_async_building` stays false, so the caller's next call proceeds
		# immediately (no polling needed) — exactly what a headless gate drives.
		_run_env_warm_pass(_async_fids, ENV_WARM_BATCH, floored_on, fallback_on, demand_on, _async_demand_axis, env_on, _async_backstop)

## REVISION 5 Stage A/B shared per-facet "have I got my FINAL cache" test — factored out of the worker's env-warm
## loop so a headless gate can drive the IDENTICAL law (via `_run_env_warm_pass`) without a compile-time sed.
## `target` = dense backstop/mid-dense role; `demand_axis` = the frozen emit axis the demand disc is centred on
## (only read when `demand_on` is true). Byte-identical to the shipped inline "have" test when `demand_on` is false.
func _env_have(fid: int, target: bool, floored_on: bool, fallback_on: bool, demand_on: bool, demand_axis: Array) -> bool:
	if not fallback_on:
		return _bpos_cache.has(fid) if target else _pos_cache.has(fid)
	if target:
		return _benv_done.has(fid) if floored_on else _bpos_cache.has(fid)
	# REVISION 5 Stage A (FP_ENV_DEMAND_DISC): outside the near-field bound, the coarse CHORD is the correct
	# TERMINAL state — count it done the moment a chord exists, never queue the ~300×-heavier envelope upgrade.
	if demand_on and not _in_env_demand_disc(fid, demand_axis):
		return _pos_cache.has(fid)
	return _env_done.has(fid)

## REVISION 5 Stage A/B: build facet `fid` toward its "have" state for ONE unit of work — the exact per-facet
## action the shipped worker loop took, factored out so the warm-only pass (Stage B) and a headless gate's
## synchronous stand-in can call it without duplicating the branch. `env_on` overrides `TierPlace.env_all_on()`/
## `TierPlace.envelope_on()` (see `_ensure_cached`/`_ensure_backstop_cached`'s own override params). `chord_fallback`
## mirrors the shipped "batch exhausted ⇒ fill the cheap chord instead" behaviour (never builds the expensive
## envelope this call). REVISION 5 Stage B hygiene fix: every rebuild below goes through the `force` parameter (a
## single in-place dictionary assignment) instead of the OLD erase-then-rebuild — a concurrent main-thread reader
## (`_cull_update`'s `_bpos_cache.keys()` scan) can no longer observe a momentarily-missing key.
func _env_build_one(fid: int, target: bool, floored_on: bool, fallback_on: bool, demand_on: bool, demand_axis: Array, env_on: bool, chord_fallback: bool) -> void:
	if chord_fallback:
		if fallback_on:
			if target and floored_on:
				_ensure_backstop_chord_cached(fid)
			else:
				_ensure_chord_cached(fid)
		return
	if target:
		# FP_ENV_FLOORED_ASYNC: a dense CHORD fallback present but not yet enveloped ⇒ force-rebuild the dense
		# ENVELOPE IN PLACE (marks _benv_done inside _ensure_backstop_cached). Off ⇒ the shipped first dense build.
		var force := floored_on and _bpos_cache.has(fid) and not _benv_done.has(fid)
		_ensure_backstop_cached(fid, force, env_on, floored_on)
		return
	# REVISION 5 Stage A: outside the demand disc, build (or leave alone) the CHEAP chord ONLY — never the envelope.
	# `_ensure_chord_cached` no-ops if the chord already exists (this call only ever runs when `_env_have` returned
	# false, i.e. no chord exists yet) — so this fills it once, terminally.
	if demand_on and not _in_env_demand_disc(fid, demand_axis):
		_ensure_chord_cached(fid)
		return
	# FP_ENV_FALLBACK_EMIT: a chord fallback present but not yet enveloped ⇒ force-rebuild the ENV envelope IN PLACE
	# (same key, single assignment — `_env_done` is set inside `_ensure_cached`'s env branch).
	var force2 := fallback_on and _pos_cache.has(fid) and not _env_done.has(fid)
	_ensure_cached(fid, force2, env_on, fallback_on)

## REVISION 5 Stage B (FP_WARM_EMIT_SPLIT): fill up to `batch` missing caches from `fids` — NO SurfaceTool, no mesh
## touch at all. This is the warm-ONLY unit of work: called by `_async_build_worker` under `_async_warm_only` (off
## the main thread, via a real WorkerThreadPool dispatch) AND directly by `_dispatch_warm_only`'s synchronous
## fallback (no real worker available) AND by a headless gate as the "synchronous stand-in for the worker cycle" —
## all three run the IDENTICAL per-facet law (`_env_have`/`_env_build_one`), so testing this function tests the
## real fix. `backstop` = the frozen dense-target snapshot (`_async_backstop`-shaped; empty ⇒ no facet is ever a
## target, matching FP_FARRING_FULL_COVER off).
func _run_env_warm_pass(fids: PackedInt32Array, batch: int, floored_on: bool, fallback_on: bool, demand_on: bool, demand_axis: Array, env_on: bool, backstop: Dictionary) -> void:
	var warmed := 0
	for fid in fids:
		if warmed >= batch:
			break
		var target := CubeSphere.FP_FARRING_FULL_COVER and backstop.has(fid)
		if _env_have(fid, target, floored_on, fallback_on, demand_on, demand_axis):
			continue
		_env_build_one(fid, target, floored_on, fallback_on, demand_on, demand_axis, env_on, false)
		warmed += 1

## WORKER THREAD: pure CPU. Emits the visible facets' cached pos/col into a SurfaceTool, computes the GLOBAL smooth
## normals, and extracts the raw surface arrays via commit_to_arrays — which, unlike commit(), creates NO mesh RID and
## touches NO RenderingServer. The arrays are BIT-IDENTICAL to what the synchronous commit() would store (proven by
## G-L1-FARRING-ASYNC). NOTHING here reads the scene tree or a rendering server.
## REVISION 5 Stage B (FP_WARM_EMIT_SPLIT): under `_async_warm_only`, this is a CACHE-FILL-ONLY pass (delegates to
## `_run_env_warm_pass`) — no SurfaceTool, no arrays; `_poll_async_rebuild` skips the mesh swap for it.
func _async_build_worker() -> void:
	var t0 := Time.get_ticks_usec()   # T2e: off-thread build wall time (read on main after is_task_completed)
	if _async_warm_only:
		_run_env_warm_pass(_async_fids, ENV_WARM_BATCH, _async_floored, CubeSphere.FP_ENV_FALLBACK_EMIT, _async_demand_on, _async_demand_axis, TierPlace.env_all_on(), _async_backstop)
		_async_arrays = []
		_async_build_us = Time.get_ticks_usec() - t0
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var warmed := 0
	# FP_ENV_FALL_HOLD: a CHORD-ONLY dispatch caps the env batch at 0 → every facet takes the cheap chord-fill path
	# below (coverage stays complete, hole=0), NO expensive env build runs. Off / not-holding ⇒ the full ENV_WARM_BATCH.
	var env_batch := 0 if _async_chord_only else ENV_WARM_BATCH
	var env_on := TierPlace.env_all_on()
	for fid in _async_fids:
		# DENSE-TARGET role read from the FROZEN snapshot (never `_excluded` live) — the const read is thread-safe.
		var target := CubeSphere.FP_FARRING_FULL_COVER and _async_backstop.has(fid)
		# V2-3b (FP_SMOOTH_V2_EXCL_BLKLOD): this facet's blocky geometry is already covered by a COMMITTED V2
		# smooth tile (the FROZEN `_async_v2_resident` snapshot, never `_smooth_v2` live off-thread) — suppress
		# only the emit below, NOT the env-warm/cache bookkeeping above/below, so the shell's own cache stays warm
		# and ready the moment V2 evicts the facet (make-before-break). Off / not resident ⇒ always false.
		var v2_excl: bool = CubeSphere.FP_SMOOTH_V2_EXCL_BLKLOD and _async_v2_resident.has(fid)
		# FP_ENV_WARM_ASYNC / FP_MID_DENSE: build this facet's cache HERE (off-thread) if it is missing, up to
		# ENV_WARM_BATCH per dispatch. A DENSE TARGET (backstop ∪ mid-dense) warms its dense _bpos_cache; every other
		# facet its coarse _pos_cache — so a promoted mid-dense facet's ~16 ms env build runs OFF-THREAD too, never on
		# the frame budget. `_async_env_warm` is the frozen main-thread decision (env_all + orbit + async), and while
		# this worker runs the main thread touches none of these caches (the `_async_building` gate), so this single
		# writer + no concurrent reader is safe. Off ⇒ `_async_env_warm` false ⇒ the block is inert (shipped read-only).
		if _async_env_warm:
			var have := _env_have(fid, target, _async_floored, CubeSphere.FP_ENV_FALLBACK_EMIT, _async_demand_on, _async_demand_axis)
			if not have:
				var batch_left := warmed < env_batch
				_env_build_one(fid, target, _async_floored, CubeSphere.FP_ENV_FALLBACK_EMIT, _async_demand_on, _async_demand_axis, env_on, not batch_left)
				if not batch_left:
					# Batch spent this cycle — the chord fallback above draws it NOW (never a hole); its upgrade lands later.
					if not v2_excl:
						if target and _bpos_cache.has(fid):
							_emit_cached(st, fid, true, true)
						elif _pos_cache.has(fid):
							_emit_cached(st, fid, false)
					continue
				warmed += 1
		# Emit by cache PRESENCE (never sunk-read a missing dense cache): a warmed/ready dense target → dense sunk; a
		# mid-dense target whose dense cache is still pending → its coarse fallback; every other facet → coarse (shipped).
		if not v2_excl:
			if target and _bpos_cache.has(fid):
				_emit_cached(st, fid, true, true)
			elif _pos_cache.has(fid):
				_emit_cached(st, fid, false)
	st.generate_normals()
	_async_arrays = st.commit_to_arrays()
	_async_build_us = Time.get_ticks_usec() - t0

## MAIN THREAD: swap a finished off-thread build onto the MeshInstance3D. The double-buffer is implicit — the previous
## _mi.mesh stayed assigned (and visible) for the whole worker run; here we replace it with the freshly built one. This
## is the ONLY RenderingServer touch of the async path (the add_surface_from_arrays / mesh RID create + assignment).
## REVISION 5 Stage B: a warm-only task (`_async_warm_only`) built caches only — no mesh to swap, just clear the flag.
func _poll_async_rebuild() -> void:
	if not _async_building:
		return
	if not WorkerThreadPool.is_task_completed(_async_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)   # already done — reclaims the handle (never blocks here)
	if _async_warm_only:
		_async_warm_only = false
	else:
		_swap_in_arrays(_async_arrays, _async_fids)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## MAIN THREAD: build the ArrayMesh from the worker's surface arrays and assign it, then update the committed-set gate
## state exactly as _rebuild_full does (so emitted_count/reemit_count/_emitted are identical to the synchronous path).
## An empty visible set (fully back-facing) yields an empty ArrayMesh — matching _build_fast's empty-mesh contract.
func _swap_in_arrays(arrays: Array, fids: PackedInt32Array) -> void:
	var t_swap := Time.get_ticks_usec()   # T2e: main-thread swap (add_surface_from_arrays / RID create + instance update)
	var mesh := ArrayMesh.new()
	var verts := 0
	if arrays.size() == Mesh.ARRAY_MAX and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		verts = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_mi.mesh = mesh
	_shell_gen += 1   # REVISION 2 LAW R-B: a real shell mesh commit landed — advances the leaving-facet handshake
	if CubeSphere.FP_SHELL_SNAP_GEN:
		_last_committed_snap_gen = _async_snap_gen   # REVISION 3 T2: this build's frozen visible_fids() snapshot has now landed
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: the async build drew the FROZEN `_async_backstop` roles as sunk
	for fid in fids:
		# FP_ENV_WARM_ASYNC: `fids` is the FULL front but the worker emitted only the facets whose cache was ready this
		# cycle (batch-bounded warm). Record ONLY those actually drawn so `_emitted` never claims an un-drawn facet. Off ⇒
		# every fid was cache-filtered before dispatch, so this guard is a no-op (byte-identical committed set).
		# FP_ENV_FALLBACK_EMIT: EVERY visible facet was drawn this cycle (its env envelope OR a cheap chord fallback), so
		# coverage is structural — record all, restoring the sh_emit == sh_visN invariant (no black holes). Off ⇒ the
		# shipped guard below records only cache-ready facets (the batch-bounded warm may leave holes).
		if _async_env_warm and not CubeSphere.FP_ENV_FALLBACK_EMIT and not _worker_cache_ready(fid):
			# FP_MID_DENSE: a mid-dense target whose dense cache is still pending WAS drawn coarse this cycle (its
			# fallback), so it is emitted — record it. A skipped backstop / uncached coarse facet was not. Off ⇒ empty.
			if _async_mid.has(fid) and _pos_cache.has(fid):
				_emitted[fid] = true
			continue
		_emitted[fid] = true
		# TIER-DEPTH P1: record as SUNK only what the worker actually drew dense (dense cache present) — a mid-dense
		# target still on its coarse fallback is NOT a sunk backstop. Off ⇒ `_async_backstop.has` (all ready). Same.
		if _async_backstop.has(fid) and _bpos_cache.has(fid):
			_emitted_backstop[fid] = true
	_reemit_count += 1
	_push_event("async", _async_build_us, Time.get_ticks_usec() - t_swap, verts)

## Warm (noise-cache) every uncached front-hemisphere facet under WARM_BUDGET_MS. Returns true once none remain
## uncached (rebuild may proceed), false when the frame budget is spent (resume next frame). The scan itself is a
## cheap cached-dot classification; only _ensure_cached (25 sphere-profile samples) is budgeted.
func _warm_front(nrm: Array, thresh: float) -> bool:
	var k := FacetAtlas.K
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# COSMOS far-ring full coverage (§4): backstop facets warm their DENSE cache; every other facet the
				# shipped grid cache. Warming on the MAIN thread here (before any async dispatch) keeps the worker's
				# read-only cache contract — the worker only ever reads _bpos_cache/_pos_cache, never builds them.
				if _dense_warm(fid):   # FP_MID_DENSE: backstop ∪ mid-dense disc warm their dense cache (main-thread here)
					if not _bpos_cache.has(fid):
						_ensure_backstop_cached(fid)
				elif not _pos_cache.has(fid):
					_ensure_cached(fid)
				if Time.get_ticks_usec() - t0 > budget_us:
					return false     # budget spent — finish warming next frame
	return true

## COSMOS-PERF FALL-COLLAPSE FIX D (FP_WARM_TRUE_BUDGET, R1) — the warm-path dispatcher. Off ⇒ the shipped _warm_front
## verbatim (byte-identical). On ⇒ the "true budget" scan below. All three _process warm sites route through here so
## surface (walk) + orbit (fall) both get the convergence fix.
func _warm_front_step(nrm: Array, thresh: float) -> bool:
	if CubeSphere.FP_WARM_TRUE_BUDGET:
		return _warm_front_true_budget(nrm, thresh)
	return _warm_front(nrm, thresh)

## COSMOS-PERF FALL-COLLAPSE FIX D (R1) — build the packed centre-dir array ONCE (6·K² Vector3). Iterated inline by
## _warm_front_true_budget so the scan avoids the per-fid _centre_dir dict lookup. Idempotent; bounded ⇒ NEVER-OOM.
func _ensure_centre_pack() -> void:
	var total := 6 * FacetAtlas.K * FacetAtlas.K
	if _centre_pack.size() == total:
		return
	_centre_pack.resize(total)
	for fid in range(total):
		var cd := _facet_centre_dir(fid)
		_centre_pack[fid] = Vector3(cd[0], cd[1], cd[2])

## COSMOS-PERF FALL-COLLAPSE FIX D (R1) — the "true warm budget" front-hemisphere warm. Scans the whole front (inline
## over the packed centre-dir array — no per-fid dict lookup / function call) and warms uncached facets, but charges
## ONLY the actual _ensure_cached WORK against WARM_BUDGET_MS, never the read-only scan. Returns true the moment a full
## scan finds NOTHING uncached — regardless of elapsed time. That is the R1 fix: the shipped _warm_front charges the
## whole 3456-facet scan against the budget, so on web ×25 the scan alone exceeds 3 ms and it returns false FOREVER even
## when every facet is cached (`done` unreachable → the idle gates never engage → ~3 ms/frame + sh_wfail burned in every
## mode). Here `done` becomes reachable, so the warm CONVERGES and the caller's idle short-circuit then stops the scan.
## `_front_visible`'s active/excluded skip is inlined (surface only, per the shipped law). NEVER-OOM: caches only grow,
## one fixed packed array. Returns false when the WARM budget is spent mid-scan (uncached facets remain — resume next frame).
func _warm_front_true_budget(nrm: Array, thresh: float) -> bool:
	_ensure_centre_pack()
	var total := 6 * FacetAtlas.K * FacetAtlas.K
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	var full_cover := CubeSphere.FP_FARRING_FULL_COVER
	var surface_skip := not full_cover and not _shell_orbit()   # the shipped active/excluded skip applies on the surface only
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	var warm_us := 0                                            # ONLY real _ensure_cached time is charged (R1)
	var clean := true                                          # no uncached front facet met this scan ⇒ converged
	for fid in range(total):
		if _centre_pack[fid].dot(nv) < thresh:                 # back-hemisphere cull (cheapest, rejects most fids) — read-only, not budgeted
			continue
		if surface_skip and (fid == _active_fid or _excluded.has(fid)):
			continue
		if _dense_warm(fid):   # FP_MID_DENSE: backstop ∪ mid-dense disc — build the dense cache, charged to the warm budget
			if not _bpos_cache.has(fid):
				clean = false
				var w0 := Time.get_ticks_usec()
				_ensure_backstop_cached(fid)
				warm_us += Time.get_ticks_usec() - w0
				if warm_us > budget_us:
					return false                              # WARM budget spent (not the scan) — more to warm next frame
		elif not _pos_cache.has(fid):
			clean = false
			var w1 := Time.get_ticks_usec()
			_ensure_cached(fid)
			warm_us += Time.get_ticks_usec() - w1
			if warm_us > budget_us:
				return false
	return clean                                              # full scan, nothing left to warm ⇒ CONVERGED (regardless of scan time)

## `thresh` is the emit cut on cd·nrm: the shipped BACK_CULL (front-hemisphere) under the active-facet law, or
## cos(θ_emit) under the COSMOS-ORBITAL-SHELL S1 camera-set law. The active/excluded skip is axis-independent
## (near voxels cover those facets), so the shell law changes only the axis (nrm) + the cut (thresh), never this.
func _front_visible(fid: int, nrm: Array, thresh: float) -> bool:
	# COSMOS FAR-CRUISE NEVER-BLACK: the sub-camera (active) facet is DIRECTLY under the camera on the floored surface —
	# it must ALWAYS be drawn. A stale / slack camera-set emit axis must never cull it into a black hole (the far-cruise
	# symptom). This forces it into every warmed / emitted / uncached-count scan (all route through here). Off / off-
	# surface / no full-cover ⇒ untouched (byte-identical); on-surface it was already a backstop, so this only defeats a
	# cull, never changes an ordinary facet.
	if CubeSphere.FP_FARRING_ACTIVE_NOBLACK and CubeSphere.FP_FARRING_FULL_COVER and fid == _active_fid and not _shell_orbit():
		return true
	# COSMOS far-ring full coverage (§2): with FP_FARRING_FULL_COVER on, the active facet + `_excluded` set are NO
	# LONGER skipped — they are drawn as sunk "backstop" facets (see _is_backstop / _emit_cached) so the near-disk
	# annular hole is filled. Only the back-hemisphere cull remains. With the flag off, the shipped exclusions apply
	# verbatim (byte-identical: active + `_excluded` absent from the visible set).
	# COSMOS-ORBITAL-SHELL live fix: the active/`_excluded` skip is a SURFACE assumption (near voxels cover those
	# facets). OFF-SURFACE (_shell_orbit) there are no near voxels over the ground under the camera, so skipping them
	# leaves a sweeping hole — the shell must draw the sub-camera facet. So the skip applies only on the surface /
	# flag-off (byte-identical). Under FULL_COVER the skip is already bypassed (they draw as backstops on the surface).
	if not CubeSphere.FP_FARRING_FULL_COVER and not _shell_orbit():
		if fid == _active_fid:
			return false                 # the near voxel world already covers the active facet (surface only)
		if _excluded.has(fid):
			return false                 # FP-R0 SPIKE: drawn as a real rotated voxel terrain, not a flat quad
	var cd := _centre_dir(fid)
	return cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] >= thresh

## COSMOS far-ring full coverage (§2): a "backstop" facet is one the near voxel world / live pool overlaps (the active
## facet or a live-pool-`_excluded` facet). Under FP_FARRING_FULL_COVER these are drawn from the dense `_bpos_cache` at
## BACKSTOP_CELLS and sunk radially by BACKSTOP_SINK at emit; every other front-hemisphere facet keeps its exact shipped
## CELLS geometry. Role is decided at emit time (keyed by the current active/excluded state), never baked into a cache.
func _is_backstop(fid: int) -> bool:
	# COSMOS-ORBITAL-SHELL live fix: OFF-SURFACE (_shell_orbit) there are no near voxels to sink behind, and the dense
	# backstop cache churns/holes as the active facet sweeps in orbit. Draw the sub-camera facet as a regular coarse
	# facet instead (coarse cache is prewarm-filled ⇒ never a warm hole; un-sunk ⇒ true surface). On the surface /
	# flag-off _shell_orbit() is false ⇒ the shipped backstop set (active ∪ `_excluded` ∪ `_sticky`), byte-identical.
	if _shell_orbit():
		return false
	return fid == _active_fid or _excluded.has(fid) or _sticky.has(fid)

## NO-PROTRUSION FIDELITY §1 F2 (FP_MID_DENSE): is the mid-ring dense promotion active at all? Requires the flag and
## FP_FARRING_FULL_COVER (the dense _bpos_cache / env builders only exist under full coverage). Off ⇒ `_mid_dense`
## stays empty ⇒ every predicate below reduces to the shipped `_is_backstop` role (byte-identical emission).
func _mid_dense_on() -> bool:
	return CubeSphere.FP_MID_DENSE and CubeSphere.FP_FARRING_FULL_COVER

## FP_MID_DENSE: the DENSE WARM TARGET — a facet whose dense _bpos_cache should be built (backstop ∪ mid-dense disc).
## Drives every WARM site (main-thread budget slice + the worker's off-thread batch) so a promoted facet's ~16 ms env
## build is scheduled EXACTLY like a backstop's — never a synchronous main-thread stall. Off ⇒ the shipped backstop set.
func _dense_warm(fid: int) -> bool:
	if not CubeSphere.FP_FARRING_FULL_COVER:
		return false
	return _is_backstop(fid) or _mid_dense.has(fid)

## FP_MID_DENSE: the DENSE EMIT role — a facet actually drawn from the dense (ε-sunk envelope) cache THIS build. A true
## backstop always emits dense (its caller pre-ensures the cache, as shipped); a promoted mid-dense facet emits dense
## ONLY once its dense cache is warmed (else it draws COARSE as a seamless fallback — no hole, no missing-key read).
## Off ⇒ `_mid_dense` empty ⇒ `FP_FARRING_FULL_COVER and _is_backstop(fid)` verbatim.
func _emit_dense(fid: int) -> bool:
	if not CubeSphere.FP_FARRING_FULL_COVER:
		return false
	if _is_backstop(fid):
		return true
	return _mid_dense.has(fid) and _bpos_cache.has(fid)

## FP_MID_DENSE: a facet promoted by the mid-ring disc that is NOT also a live backstop (the transient-coarse-fallback
## class). Off / not promoted ⇒ false.
func _is_mid_dense(fid: int) -> bool:
	return _mid_dense.has(fid) and not _is_backstop(fid)

## COSMOS PLANET-VIEW §3 (B) — FP_FARRING_LIMB_DENSE: is facet `fid` on the CURRENT silhouette ring? Reads ONLY the frozen
## `_limb_set` (computed on the main thread at the last rebuild/dispatch), so it is race-free on the async worker. Empty
## with the flag off / on the surface ⇒ false everywhere ⇒ byte-identical.
func _is_limb_dense(fid: int) -> bool:
	return _limb_set.has(fid)

## COSMOS PLANET-VIEW §3 (B): the PURE silhouette-ring test, factored static so the headless gate drives it with synthetic
## d/R. A facet whose centre makes angle φ = acos(centre·ĉ) with the sub-camera axis ĉ is on the limb ring when it is within
## `band_rad` of the horizon-tangent angle θ_h = acos(cos_theta_h) (cos θ_h = R/d). Symmetric about the tangent so the ring
## is ~1 facet thick on BOTH sides of the exact silhouette.
static func is_limb_facet(centre_dot_c: float, cos_theta_h: float, band_rad: float) -> bool:
	var phi := acos(clampf(centre_dot_c, -1.0, 1.0))
	var th := acos(clampf(cos_theta_h, -1.0, 1.0))
	return absf(phi - th) < band_rad

## The cube-sphere facet angular HALF-width (rad) = half the facet edge angle (π/2K). The limb band is LIMB_DENSE_BAND × this.
static func _facet_half_angle() -> float:
	return (PI * 0.5 / float(FacetAtlas.K)) * 0.5

## COSMOS PLANET-VIEW §3 (B): recompute the silhouette-ring set from the CURRENT emit-axis/horizon snapshot and REAP stale
## dense caches. Called on the MAIN thread at each rebuild/dispatch (before the worker reads `_limb_set`), passed the visible
## fids so it only ever considers emitted facets. ONLY off-surface (orbit) under the camera-set law; on the surface / with the
## flag off it clears the set + reaps ALL limb caches ⇒ `_is_limb_dense` false everywhere (byte-identical). Bounds the resident
## dense set to LIMB_DENSE_MAX_FACETS (closest-to-tangent kept) — NEVER-OOM. Rides the EXISTING cap-drift/re-emit cadence (no
## new re-emit trigger): the axis/θ_h only change on a `_shell_snapshot`, so the ring is only recomputed when a rebuild fires.
func _refresh_limb_set(fids: PackedInt32Array) -> void:
	var want := {}
	if CubeSphere.FP_FARRING_LIMB_DENSE and _offsurface and _cam_set and _emit_thetah_last >= 0.0:
		var cos_th := cos(_emit_thetah_last)              # = R/d at the last snapshot (the horizon tangent)
		var band := LIMB_DENSE_BAND * _facet_half_angle()
		var picked: Array = []
		for fid in fids:
			var cd := _centre_dir(fid)
			var dot: float = cd[0] * _emit_axis[0] + cd[1] * _emit_axis[1] + cd[2] * _emit_axis[2]
			if is_limb_facet(dot, cos_th, band):
				# key = angular distance from the exact tangent (so the cap trim keeps the truest limb facets)
				picked.append([absf(acos(clampf(dot, -1.0, 1.0)) - _emit_thetah_last), int(fid)])
		if picked.size() > LIMB_DENSE_MAX_FACETS:
			picked.sort()                                 # ascending by |Δ|; keep the closest-to-tangent cap-many
			picked.resize(LIMB_DENSE_MAX_FACETS)
		for e in picked:
			want[int((e as Array)[1])] = true
	_limb_set = want
	# Reap dense caches no longer on the ring so resident bytes track the CURRENT limb only (bounded ⇒ NEVER-OOM).
	for fid in _limb_pos_cache.keys():
		if not want.has(fid):
			_limb_pos_cache.erase(fid)
			_limb_col_cache.erase(fid)

## COSMOS PLANET-VIEW §3 (B): build (once) facet `fid`'s DENSE (LIMB_DENSE_CELLS) ABSOLUTE-coord, UN-SUNK terrain grid,
## mirroring `_ensure_cached`'s env/weld/planar branch structure at the higher resolution so it welds to its CELLS=4 coarse
## neighbours (EDGE-CANON shared-node values are resolution-independent). Idempotent + pure sampling (profile_at_dir +
## FacetAtlas only), so it is safe to warm lazily on the async worker (single-writer under the `_async_building` gate).
func _ensure_limb_cached(fid: int) -> void:
	if _limb_pos_cache.has(fid):
		return
	var cells := LIMB_DENSE_CELLS
	var g: Array
	if TierPlace.env_all_on():
		g = _env_weld_grid(fid, cells)                    # min-envelope dense grid (same builder the backstop uses)
	elif CubeSphere.FP_SHELL_WELD:
		g = _weld_chord_arrays_n(fid, cells)              # radial weld from the shared corner dirs
	else:
		g = _planar_grid_arrays(fid, cells)               # shipped planar-corner path at the denser resolution
	_limb_pos_cache[fid] = g[0]
	_limb_col_cache[fid] = g[1]

## COSMOS PLANET-VIEW §3 (B): the `cells`-parametrized twin of `_weld_chord_arrays` (which is hardcoded to CELLS). Same
## radial weld, denser grid. Used only by the limb path (gated) so the shipped CELLS builder is untouched (byte-identical).
func _weld_chord_arrays_n(fid: int, cells: int) -> Array:
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var stride := cells + 1
	for gj in range(stride):
		for gi in range(stride):
			_weld_node(cd, float(gi) / float(cells), float(gj) / float(cells), pos, col)
	return [pos, col]

## COSMOS PLANET-VIEW §3 (B): the `cells`-parametrized twin of `_ensure_cached`'s shipped planar-corner path. Same bilerp +
## radial-relief construction, denser grid. Used only by the limb path (gated) so the shipped builder is untouched.
func _planar_grid_arrays(fid: int, cells: int) -> Array:
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	return [pos, col]

## COSMOS PLANET-VIEW §3 (B): expand a limb facet's dense grid into the fast-path tri soup (same two tris/cell, same winding,
## same per-vertex colours as `_emit_cached`) and append to `_build_fast`'s packed arrays — the limb analogue of
## `_append_backstop_tris`. Un-sunk (ε-sunk under env_all, matching the coarse emit) so it welds to the coarse neighbours.
func _append_limb_tris(pos: PackedVector3Array, col: PackedColorArray, fid: int,
		uv: PackedVector2Array = PackedVector2Array(), uv2: PackedVector2Array = PackedVector2Array()) -> void:
	_ensure_limb_cached(fid)
	var gp: PackedVector3Array = _sunk_positions(_limb_pos_cache[fid]) if TierPlace.env_all_on() else _limb_pos_cache[fid]
	var gc: PackedColorArray = _limb_col_cache[fid]
	var cells := LIMB_DENSE_CELLS
	var stride := cells + 1
	var tex := _tex_on()
	var t_a := 0; var t_b := 0; var t_k := 1
	var fuv2 := Vector2.ZERO; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		fuv2 = Vector2(float(d[0]), _uv2_y(fid))
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k); inv_c = 1.0 / float(cells)
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			pos.push_back(gp[i0]); pos.push_back(gp[i2]); pos.push_back(gp[i1])
			pos.push_back(gp[i1]); pos.push_back(gp[i2]); pos.push_back(gp[i3])
			col.push_back(gc[i0]); col.push_back(gc[i2]); col.push_back(gc[i1])
			col.push_back(gc[i1]); col.push_back(gc[i2]); col.push_back(gc[i3])
			if tex:
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				uv.push_back(Vector2(u0, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v0))
				uv.push_back(Vector2(u1, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v1))
				for _i in range(6):
					uv2.push_back(fuv2)

# --- COSMOS TEXTURED-LOD U2 (FP_FARRING_CULL_COVERED, §2U.3): occlusion-cull covered backstop cells -------------------

## Wire the near-coverage callable (fid, fid-lattice AABB) -> bool — the SAME signal the skin's covered-tile skip uses,
## routed by WorldManager to module_world.skin_near_meshed (godot_voxel is_area_meshed). An INVALID callable (no module /
## GDScript fallback path) leaves the cull inert ("never covered" ⇒ nothing culled) — the design's disclosed fallback.
func set_cover_query(q: Callable) -> void:
	_cull_cover_query = q

## Is the U2 cull active this run? Requires the flag AND a valid coverage callable (module path). Off / no query ⇒ no
## cell is ever suppressed and no state is allocated → byte-identical.
func _cull_on() -> bool:
	return CubeSphere.FP_FARRING_CULL_COVERED and _cull_cover_query.is_valid()

## COSMOS TEXTURED-LOD U3 (FP_FARRING_LEVEL, §2U.3): is the SAME-LEVEL sink reduction active this run? Requires the
## flag AND the U2 cull actually running (_cull_on: FP_FARRING_CULL_COVERED + a VALID coverage probe) — the sink can
## only collapse to the ε guard where the cull guarantees near/far never coexist. Off / no query ⇒ the full backstop
## sink stays (self-disables to today's sink on the GDScript fallback path). Byte-identical when either flag is off.
func _level_on() -> bool:
	return CubeSphere.FP_FARRING_LEVEL and _cull_on()

## THE ASYMMETRIC-HYSTERESIS STATE MACHINE (headlessly testable — the gate drives it with mocked booleans). Advance cell
## `ci` of facet `fid` by ONE coverage read `covered`. Culling requires CULL_CONFIRM consecutive COVERED reads; un-culling
## is INSTANT on the first UNcovered read (streak → 0, mask bit cleared). Returns the new culled bit. Latches `_cull_changed`
## on any flip so `_process` re-emits. Holes are worse than overdraw, so every ambiguity resolves toward DRAWING.
## INVARIANT (G-CV-SAFE): the returned bit is 1 ⇒ the LAST read was covered ⇒ culled ⊆ covered, ALWAYS.
func cull_feed(fid: int, ci: int, covered: bool) -> bool:
	var ncell := CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS
	if ci < 0 or ci >= ncell:
		return false
	var mask: PackedByteArray = _cull_mask.get(fid, PackedByteArray())
	var streak: PackedByteArray = _cull_streak.get(fid, PackedByteArray())
	if mask.size() != ncell:
		mask = PackedByteArray(); mask.resize(ncell)   # zero-filled: nothing culled
		streak = PackedByteArray(); streak.resize(ncell)
	var was: int = mask[ci]
	if covered:
		var s: int = streak[ci]
		if s < CubeSphere.CULL_CONFIRM:
			s += 1
		streak[ci] = s
		mask[ci] = 1 if s >= CubeSphere.CULL_CONFIRM else 0
	else:
		streak[ci] = 0
		mask[ci] = 0                                     # INSTANT un-cull — the first uncovered read always draws
	if mask[ci] != was:
		_cull_changed = true
	_cull_mask[fid] = mask
	_cull_streak[fid] = streak
	return mask[ci] == 1

## Emit-time read: does the CURRENT mesh suppress facet `fid`'s cell `ci`? Reads the COMMITTED snapshot (NOT the live
## churning mask) so the emitted geometry only ever changes at a rebuild — never per probe. False unless the cull is
## active. Pure lookup.
func is_cell_culled(fid: int, ci: int) -> bool:
	if not _cull_on():
		return false
	var mask: PackedByteArray = _committed_cull.get(fid, PackedByteArray())
	return ci >= 0 and ci < mask.size() and mask[ci] == 1

## Would any committed-culled cell be a HOLE right now — i.e. is it un-culled in the LIVE mask (near has retreated /
## un-meshed there)? Drives the prompt FLUSH safety path. A committed 1 with a live 0 means the mesh omits a cell the near
## field no longer covers ⇒ must re-emit. The +CULL_DILATE dilation makes the live 0 arrive while the tight cell is still
## covered, so this fires BEFORE an actual hole.
func _cull_committed_unsafe() -> bool:
	for fid in _committed_cull.keys():
		var cm: PackedByteArray = _committed_cull[fid]
		var lm: PackedByteArray = _cull_mask.get(fid, PackedByteArray())
		for ci in range(cm.size()):
			if cm[ci] == 1 and (ci >= lm.size() or lm[ci] == 0):
				return true
	return false

## Do the live and committed masks differ in their EFFECTIVE cull set (which cells are 1)? An all-zero facet array and an
## absent facet are equal (both cull nothing) — so an APPLY of a mask that culls nothing never fires a spurious rebuild.
func _cull_mask_differs() -> bool:
	for fid in _cull_mask.keys():
		if _facet_cull_differs(_cull_mask[fid], _committed_cull.get(fid, PackedByteArray())):
			return true
	for fid in _committed_cull.keys():
		if not _cull_mask.has(fid) and _any_bit_set(_committed_cull[fid]):
			return true
	return false

## Bit-wise cull difference between two per-facet arrays, treating an out-of-range index as 0.
func _facet_cull_differs(a: PackedByteArray, b: PackedByteArray) -> bool:
	var n := maxi(a.size(), b.size())
	for ci in range(n):
		var av: int = a[ci] if ci < a.size() else 0
		var bv: int = b[ci] if ci < b.size() else 0
		if av != bv:
			return true
	return false

func _any_bit_set(a: PackedByteArray) -> bool:
	for v in a:
		if v == 1:
			return true
	return false

## Deep-copy the live mask into the committed snapshot (APPLY). PackedByteArrays are value types; duplicate so a later live
## mutation cannot alias the committed emit source.
func _cull_commit_apply() -> void:
	_committed_cull.clear()
	for fid in _cull_mask.keys():
		_committed_cull[fid] = (_cull_mask[fid] as PackedByteArray).duplicate()

## Clear the committed snapshot (FLUSH → full emission). Used by the safety path so a stale cull can never outlive the
## near coverage that justified it.
func _cull_commit_flush() -> void:
	_committed_cull.clear()

## DECOUPLED rebuild decision (round-2 live-perf fix — headlessly testable; `now_ms` injectable). Given the freshly-probed
## live mask this pass and whether it changed, decide whether the far ring must re-emit, and update the committed snapshot:
##   FLUSH  — a committed-culled cell just un-culled (near retreated): clear committed to full emission NOW (safety, holes
##            worse than overdraw), un-rate-limited. Returns true.
##   APPLY  — the live mask has been STABLE for CULL_SETTLE_PROBES probes AND differs from committed AND ≥ CULL_REBUILD_MS
##            since the last APPLY: copy the live mask into committed (the settled standing-still optimization). Returns true.
##   else   — no rebuild (committed unchanged) → during sustained streaming the churning live mask triggers NOTHING.
func _cull_decide_reemit(changed: bool, now_ms: int) -> bool:
	_cull_stable_probes = 0 if changed else _cull_stable_probes + 1
	if _cull_committed_unsafe():
		_cull_commit_flush()
		_cull_reemit_count += 1
		return true
	if _cull_stable_probes >= CubeSphere.CULL_SETTLE_PROBES and _cull_mask_differs() \
			and now_ms - _cull_last_reemit_ms >= CubeSphere.CULL_REBUILD_MS:
		_cull_commit_apply()
		_cull_last_reemit_ms = now_ms
		_cull_reemit_count += 1
		return true
	return false

## The fid-lattice AABB the coverage probe asks about for backstop cell (gi,gj), DILATED by ±CULL_DILATE horizontally and
## banded by ±CULL_Y_MARGIN radially. Built from the cell's 4 dense-cache corner positions (ABSOLUTE world) mapped back to
## the facet's own lattice via FacetAtlas.world_to_lattice64 — the SAME frame godot_voxel's is_area_meshed operates in (as
## skin_near_meshed documents), so no new remap is introduced. Dilation makes the probed box a SUPERSET of the visible
## cell ⇒ is_area_meshed (which is true only when the WHOLE box is meshed) gets STRICTER, i.e. cull is harder / safer, and
## the box uncovers at its dilated boundary while the tight cell is still covered → the cell re-emits before near retreats.
func _cull_cell_aabb(fid: int, gi: int, gj: int) -> AABB:
	var pos: PackedVector3Array = _bpos_cache[fid]
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var i0 := gj * stride + gi
	var idx := [i0, i0 + 1, i0 + stride, i0 + stride + 1]
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for k in idx:
		var p: Vector3 = pos[k]
		var l: Array = FacetAtlas.world_to_lattice64(fid, p.x, p.y, p.z)
		var lx := float(l[0]); var ly := float(l[1]); var lz := float(l[2])
		lo.x = minf(lo.x, lx); lo.y = minf(lo.y, ly); lo.z = minf(lo.z, lz)
		hi.x = maxf(hi.x, lx); hi.y = maxf(hi.y, ly); hi.z = maxf(hi.z, lz)
	var d := CubeSphere.CULL_DILATE
	var ym := CubeSphere.CULL_Y_MARGIN
	var pos_lo := Vector3(lo.x - d, lo.y - ym, lo.z - d)
	var size := Vector3((hi.x - lo.x) + 2.0 * d, (hi.y - lo.y) + 2.0 * ym, (hi.z - lo.z) + 2.0 * d)
	return AABB(pos_lo, size)

## Probe cell (gi,gj) of backstop facet `fid`: ask the near-coverage callable whether the dilated fid-lattice AABB is fully
## meshed. False on an invalid callable (fallback path) — never over-cull. Main thread only (reads the live _bpos_cache).
func _cull_probe_cell(fid: int, gi: int, gj: int) -> bool:
	if not _cull_cover_query.is_valid():
		return false
	return bool(_cull_cover_query.call(fid, _cull_cell_aabb(fid, gi, gj)))

## Per-frame (from `_process`, throttled to CULL_REAP_MS): re-probe every cell of every LIVE backstop facet whose dense cache
## exists, advancing the hysteresis state machine (cheap O(cells) — is_area_meshed octree reads only). Prunes the masks to
## the current backstop set (NEVER-OOM). Then the DECOUPLED decision (`_cull_decide_reemit`) fires a far-ring rebuild ONLY
## on a settle (APPLY) or a safety (FLUSH) transition — NOT per probe — so the ~1 s sync rebuild can no longer run every
## frame as coverage churns under live streaming (the round-2 regression). No-op unless the cull is active.
func _cull_update() -> void:
	if not _cull_on():
		if not _cull_mask.is_empty() or not _committed_cull.is_empty():
			_cull_mask.clear(); _cull_streak.clear(); _committed_cull.clear()   # flag flipped off mid-run — drop all state
		return
	var now := Time.get_ticks_msec()
	if now - _cull_last_ms < CubeSphere.CULL_REAP_MS:
		return
	_cull_last_ms = now
	_cull_changed = false                                # per-pass live-mask-change latch (settle detector)
	var cells := CubeSphere.BACKSTOP_CELLS
	# The set of facets that CAN be near-covered = live backstop facets with a dense cache (near meshes only around them).
	var live := {}
	for fid in _bpos_cache.keys():
		if _is_backstop(fid):
			live[fid] = true
			for gj in range(cells):
				for gi in range(cells):
					cull_feed(fid, gj * cells + gi, _cull_probe_cell(fid, gi, gj))
	# Prune LIVE + streak state for facets no longer backstop (bounded footprint); a committed facet that left the set is
	# dropped too, and that counts as a live-mask change so the settle counter restarts (the committed emit is stale).
	for fid in _cull_mask.keys():
		if not live.has(fid):
			_cull_mask.erase(fid); _cull_streak.erase(fid)
			_cull_changed = true
	for fid in _committed_cull.keys():
		if not live.has(fid):
			_committed_cull.erase(fid)
			_cull_changed = true
	# DECOUPLED: rebuild only on a settle/safety transition — never per probe.
	if _cull_decide_reemit(_cull_changed, now):
		_pending = true                                 # re-emit through whichever _process path is active

## FP_MID_DENSE gate visibility: does facet `fid` emit from the dense cache right now? (public accessor for
## verify_no_protrusion's mid-dense reconstruction tier.)
func is_dense_emit(fid: int) -> bool:
	return _emit_dense(fid)

## FP_MID_DENSE gate visibility: is facet `fid` currently PROMOTED into the ring-2 disc? (independent of whether its
## dense cache is warmed yet — the gate reconstructs the dense as-rendered surface it WILL draw once warmed.)
func is_mid_dense_promoted(fid: int) -> bool:
	return _mid_dense.has(fid)

## FP_MID_DENSE bytes-ledger accessor: the count of currently mid-dense-promoted facets (for the NEVER-OOM gate assertion).
func mid_dense_count() -> int:
	return _mid_dense.size()

## FP_MID_DENSE §1 F2: recompute the ring-2 dense-promotion disc around the current emit axis `p[0]` (the sub-camera /
## player direction), and REAP any previously-promoted dense cache that has left the disc AND is not a live backstop —
## so `_bpos_cache` stays bounded to backstop ∪ ring-2 (the stated NEVER-OOM ceiling), even as the sub-point sweeps the
## globe in orbit. Main thread only, and only from `_process` AFTER the `_async_building` guard (the worker reads
## `_bpos_cache`, so the reap never races it). Axis-gated: a still camera re-runs nothing (steady-state zero cost).
## No-op with FP_MID_DENSE off (the flag guard clears any residue and returns) ⇒ byte-identical.
func _recompute_mid_dense(p: Array) -> void:
	if not _mid_dense_on():
		if not _mid_dense.is_empty():
			_reap_mid_dense({})            # flag flipped off mid-run — drop all promotions, free their caches
			_mid_dense = {}
		return
	var nrm: Array = p[0]
	var nx := float(nrm[0]); var ny := float(nrm[1]); var nz := float(nrm[2])
	# Axis-change gate: skip the scan while the emit axis is essentially unchanged (the disc, hence the promoted set,
	# is unmoved). MID_DENSE_AXIS_HOLD_COS ≈ cos(¼ facet-edge) — far tighter than the disc so a facet never straddles.
	var hold_cos := 1.0 - 0.25 * (1.0 - _mid_dense_threshold())   # a small fraction of the disc half-angle
	if not _mid_dense.is_empty() and _mid_dense_axis[0] * nx + _mid_dense_axis[1] * ny + _mid_dense_axis[2] * nz >= hold_cos:
		return
	_mid_dense_axis = [nx, ny, nz]
	var cos_thr := _mid_dense_threshold()
	var next := {}
	var k := FacetAtlas.K
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				var cd := _centre_dir(fid)
				if cd[0] * nx + cd[1] * ny + cd[2] * nz >= cos_thr:
					next[int(fid)] = true
	_reap_mid_dense(next)
	_mid_dense = next

## FP_MID_DENSE: cos(MID_DENSE_RINGS · facet-edge angle). Facet edge subtends ≈ (π/2)/K rad at a face centre; the disc
## radius is MID_DENSE_RINGS of those. Computed once (cached).
func _mid_dense_threshold() -> float:
	if _mid_dense_cos == 0.0:
		var facet_ang := (PI * 0.5) / float(FacetAtlas.K)
		_mid_dense_cos = cos(CubeSphere.MID_DENSE_RINGS * facet_ang)
	return _mid_dense_cos

## REVISION 5 Stage A (FP_ENV_DEMAND_DISC): cos(ENV_DEMAND_RINGS · facet-edge angle) — the SAME derivation as
## _mid_dense_threshold, just a wider radius. Computed once (cached).
func _env_demand_threshold() -> float:
	if _env_demand_cos == 0.0:
		var facet_ang := (PI * 0.5) / float(FacetAtlas.K)
		_env_demand_cos = cos(CubeSphere.ENV_DEMAND_RINGS * facet_ang)
	return _env_demand_cos

## REVISION 5 Stage A: is facet `fid` within ENV_DEMAND_RINGS facet-edges of the given axis `nrm` (the current emit
## axis — under the floored regime that IS the sub-camera/player direction)? The min-envelope is a no-protrusion
## bound against the NEAR field, and near meshes only ever exist within near_render_radius()+RIM_STREAM_MARGIN of
## the player (backstop ∪ mid-dense ∪ a couple of rings) — a facet further out has nothing to protrude through, so
## its exact chord IS its correct terminal state. Same angular-disc test FP_MID_DENSE already uses (`_centre_dir`
## dotted against the axis, compared to a cos threshold).
func _in_env_demand_disc(fid: int, nrm: Array) -> bool:
	var cd := _centre_dir(fid)
	var nx := float(nrm[0]); var ny := float(nrm[1]); var nz := float(nrm[2])
	return cd[0] * nx + cd[1] * ny + cd[2] * nz >= _env_demand_threshold()

## FP_MID_DENSE: free the dense cache of every promoted facet NOT in `keep` and NOT a live backstop (whose dense cache
## the backstop role still needs). Bounded ⇒ NEVER-OOM. Called only on the main thread while the worker is idle.
func _reap_mid_dense(keep: Dictionary) -> void:
	for fid in _mid_dense.keys():
		var f := int(fid)
		if keep.has(f) or _is_backstop(f):
			continue
		_bpos_cache.erase(f)
		_bcol_cache.erase(f)
		_benv_done.erase(f)   # FP_ENV_FLOORED_ASYNC: drop the "dense-enveloped" flag with the cache it describes, else a
		                      # later re-promotion rebuilds a cheap chord but _emit_cached still reads the ε sink (protrusion)
		                      # and the warm/count paths think it is converged (stale coverage).
		_btrue_cache.erase(f)   # FP_FARRING_UNCOVERED_TRUE: reap the true chord alongside the departing dense cache

## COSMOS TIER-DEPTH-PRIORITY P1 (§5.3): recompute the sticky backstop set on a role-event (set_active / set_pool_excluded
## / setup). Make-before-break: the TARGET = active ∪ ring-1 neighbours (the design's set; a facet the player can cross into
## is a seam neighbour = ring-1, so it is already drawn sunk BEFORE it enters the pool and near meshes arrive). Unsink-late
## ("recently-active"): a facet that WAS sticky but is no longer a target keeps its role for STICKY_HOLD more role-events (a
## hold countdown), so a just-departed facet never reverts to a coarse unsunk quad while its near meshes may still be
## applied. Pool facets OUTSIDE ring-1 are already backstop via `_excluded.has` (unioned in `_is_backstop`) and revert
## benignly (a dip) when they leave — so they are deliberately NOT unioned into the TARGET, keeping `_sticky` rigorously
## bounded by ring-1 (≤ STICKY_RING1_MAX, the +96 kB dense-cache ceiling). No-op (empty `_sticky`) unless the flag is on.
func _recompute_sticky() -> void:
	if not TierPlace.sticky_on():
		return
	var target := {}
	for f in TierPlace.ring1(_active_fid):
		target[int(f)] = true
	# Grow eagerly: every target is sticky now, hold refreshed to full.
	for f in target.keys():
		_sticky[int(f)] = true
		_sticky_hold[int(f)] = CubeSphere.STICKY_HOLD
	# Shrink lazily: a sticky facet no longer targeted decrements its hold; only at 0 does it drop.
	for f in _sticky.keys():
		if target.has(int(f)):
			continue
		var h := int(_sticky_hold.get(int(f), 0)) - 1
		if h <= 0:
			_sticky.erase(int(f))
			_sticky_hold.erase(int(f))
		else:
			_sticky_hold[int(f)] = h

## The full scan + re-emit + commit (the OLD _rebuild). Runs at setup, from _process once warming completes, and
## from force_rebuild (the gate). NOT called synchronously by a crossing — that is the whole point of FP-S1(d).
func _rebuild_full() -> void:
	transform = _placement_xform()   # absolute → active-lattice render frame (identity under FP-FIXED-FRAME)
	_refresh_slot_snapshot()         # COSMOS LOD-TEXTURE Phase 4: freeze the close-up slot map for this build (no-op off)
	# REVISION 3 T2 (FP_SHELL_SNAP_GEN): a synchronous build's snapshot + commit happen in this SAME call (no in-flight
	# window), so bumping here and reading back at commit time below is trivially consistent — off ⇒ stays 0.
	if CubeSphere.FP_SHELL_SNAP_GEN:
		_snap_gen += 1
	var this_snap_gen := _snap_gen
	var fids := visible_fids(_emit_cached_only)   # S1b: cache-filtered in the true-orbit progressive path, full set otherwise (shipped)
	_refresh_limb_set(fids)          # COSMOS PLANET-VIEW §3 (B): freeze the silhouette-ring set + reap stale limb caches (no-op off)
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: record which fids this build draws SUNK (the make-before-break gate reads it)
	for fid in fids:
		_ensure_emit_cached(fid)
		_emitted[fid] = true
		if _emit_dense(fid):   # FP_MID_DENSE: backstop ∪ ready mid-dense are drawn dense (SUNK) — _ensure_emit_cached built the cache
			_emitted_backstop[fid] = true
	# COSMOS-PERF L1: pick the mesh assembler. FAST = packed-array memcpy + one add_surface_from_arrays; the shipped
	# SurfaceTool path stays the default (byte-identical mesh). Both consume the SAME visible fids in the SAME order.
	# T2e: time the mesh BUILD (assembler) and the SWAP (mesh assign / RID create + instance update) separately — two
	# ticks_usec reads either side of the split assignment, telemetry-only, no behavioural change.
	var t_build := Time.get_ticks_usec()
	# FP_BLOCKY_FARRING: the fast (memcpy) path replays a pre-triangulated SMOOTH tri soup — route the sync rebuild
	# through _build_surfacetool → _emit_cached so it emits BLOCKS. Off ⇒ the shipped fast/surfacetool choice (byte-identical).
	var new_mesh: Mesh = _build_fast(fids) if (CubeSphere.FP_FARRING_FAST_REBUILD and not CubeSphere.FP_BLOCKY_FARRING) else _build_surfacetool(fids)
	var build_us := Time.get_ticks_usec() - t_build
	var t_swap := Time.get_ticks_usec()
	_mi.mesh = new_mesh
	_shell_gen += 1   # REVISION 2 LAW R-B: a real shell mesh commit landed — advances the leaving-facet handshake
	if CubeSphere.FP_SHELL_SNAP_GEN:
		_last_committed_snap_gen = this_snap_gen   # REVISION 3 T2: this build's frozen visible_fids() snapshot has now landed
	var swap_us := Time.get_ticks_usec() - t_swap
	_reemit_count += 1
	_pending = false
	# 32 tris/facet at CELLS=4; under FULL_COVER the backstop facets are denser (2·BACKSTOP_CELLS²) — count them exactly.
	var tris := fids.size() * CELLS * CELLS * 2
	if CubeSphere.FP_FARRING_FULL_COVER:
		var extra := (CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS - CELLS * CELLS) * 2
		for fid in fids:
			if _emit_dense(fid):   # FP_MID_DENSE: dense facets (backstop ∪ ready mid-dense) carry the denser tri count
				tris += extra
	if CubeSphere.FP_FARRING_LIMB_DENSE and not _limb_set.is_empty():
		tris += _limb_set.size() * (LIMB_DENSE_CELLS * LIMB_DENSE_CELLS - CELLS * CELLS) * 2   # limb-ring facets carry the denser tri count
	_push_event("sync", build_us, swap_us, tris * 3)   # T2e: verts = 3·tris (cheap; no surface read-back on the crossing frame)
	print("[FP2] facet far ring: %d triangles around facet %d (%d facets cached, %d backstop)" % [tris, _active_fid, _pos_cache.size(), _bpos_cache.size()])

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 4 Stage B (FP_RING_QUIESCE, R4.2): the ONE emit-exclusion predicate
## — factored out of the inline check `visible_fids()` used below (§2 law 6) so every OTHER caller that needs to know
## "is this facet's coverage already handled by the smooth tile, not the shell" shares the identical definition
## (`_noblack_guarantee` + both uncached/uncovered counters — see FP_RING_QUIESCE below). A facet is smooth-covered
## when its S2 tile is RESIDENT and NOT mid-leaving-handshake (`_smooth_leaving` — REVISION 2 LAW R-B make-before-
## break: a leaving facet must re-appear in the shell's emit BEFORE the tile actually drops, so it is not "covered"
## during that window either). `_smooth` is null unless FP_FAR_SMOOTH ⇒ always false off. This extraction itself is
## an unconditional refactor of already-shipped logic (not flag-gated) — `visible_fids()`'s behaviour is unchanged
## either way; FP_RING_QUIESCE only gates whether the OTHER two call sites also honour it.
func _smooth_covered(fid: int) -> bool:
	return _smooth != null and _smooth.is_resident(fid) and not _smooth_leaving.has(fid)

## The front-hemisphere visible fid set (front-facing, non-active, non-excluded), in canonical face/a/b order. Both
## mesh assemblers + the equivalence gate consume this so their vertex/color/normal arrays are index-aligned.
func visible_fids(cached_only := false) -> PackedInt32Array:
	var out := PackedInt32Array()
	var k := FacetAtlas.K
	# COSMOS-ORBITAL-SHELL S1: the same cull axis + threshold _warm_front consumed, so the warmed and emitted sets agree.
	var p := _cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# S1b: the true-orbit progressive path emits only cache-ready facets (grows as the cache fills); every
				# other caller passes cached_only=false ⇒ the shipped full front set (byte-identical).
				if cached_only and not _emit_cache_ready(fid):
					continue
				# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 6 (P1 emit-exclusion): once a facet's smooth tile has
				# COMMITTED, the shell/heightfield stops emitting it — "smooth-until-ready" (it keeps emitting until
				# then, so there is never a frame with neither). Every consumer of `visible_fids()` (this rebuild, the
				# async worker's fid set, the boot-warm proximity order, …) shares this ONE filter, so the exclusion is
				# consistent everywhere. `_smooth` is null unless FP_FAR_SMOOTH ⇒ byte-identical off.
				# REVISION 2 LAW R-B (FP_SMOOTH_MESH_INC): a facet marked `_smooth_leaving` is STILL smooth-resident
				# (the tile stays drawn — make-before-break) but must start appearing in the shell's emit again RIGHT
				# NOW, so the next shell commit re-includes it BEFORE the smooth tile is actually dropped (never a
				# frame where neither system draws it). Off ⇒ `_smooth_leaving` is always empty (byte-identical).
				# REVISION 4 Stage B: this check is now the shared `_smooth_covered(fid)` predicate (identical logic,
				# extracted so `_noblack_guarantee`/the uncached/uncovered counters can reuse it under FP_RING_QUIESCE).
				if _smooth_covered(fid):
					continue
				out.append(fid)
	return out

## COSMOS-ORBITAL-SHELL S1b (§3): is facet `fid`'s emit cache present? Backstop facets (FULL_COVER) render from the
## dense _bpos_cache; every other facet from the shipped coarse _pos_cache. Used to filter the progressive orbit set
## so the async worker (and the sync assembler) only ever touch a facet whose cache exists.
func _emit_cache_ready(fid: int) -> bool:
	if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
		return _bpos_cache.has(fid)
	# FP_MID_DENSE: a promoted mid-dense facet is ready as soon as its COARSE cache exists (it draws coarse as a
	# seamless fallback until its dense cache is warmed) — so a mid-distance facet is NEVER filtered to a hole while
	# its heavy env cache builds. Off ⇒ this is the shipped coarse readiness for every non-backstop facet.
	return _pos_cache.has(fid)

## SHIPPED assembler: per-vertex SurfaceTool emission + generate_normals (the ~332k GDScript→C++ round-trip path).
func _build_surfacetool(fids: PackedInt32Array) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids:
		_ensure_emit_cached(fid)
		# V2-3b (FP_SMOOTH_V2_EXCL_BLKLOD): this is the MAIN-THREAD sync path (`_rebuild_full`, never called
		# synchronously from a crossing), so `_smooth_v2.is_resident()` is read LIVE (safe, same-thread) — mirrors
		# `_is_backstop`'s own live-on-sync-path / frozen-on-async-path split (see `_emit_cached`'s doc comment).
		# Cache warming above still runs unconditionally (make-before-break: the shell's cache stays ready for the
		# instant V2 evicts this facet); only the geometry actually added to `st` is suppressed. Off / no
		# `_smooth_v2` / not resident ⇒ the shipped unconditional emit (byte-identical).
		if CubeSphere.FP_SMOOTH_V2_EXCL_BLKLOD and CubeSphere.FP_BLOCKY_FARRING and _smooth_v2 != null and _smooth_v2.is_resident(int(fid)):
			continue
		_emit_cached(st, fid, _emit_dense(fid))   # main thread — live role is safe; _ensure_emit_cached built the dense cache
	st.generate_normals()
	return st.commit()

## FAST assembler (L1): concat the pre-triangulated per-facet pos/col caches into two big packed arrays (C++ memcpy),
## build a normal-less mesh, then let SurfaceTool COMPUTE the normals via create_from + generate_normals — both C++,
## so NONE of the ~332k per-vertex GDScript→C++ round-trips of the shipped path remain, yet the normals are the SAME
## GLOBALLY-smoothed array (create_from replays the identical vertex list into the identical generate_normals, seams
## and all). A few ms of memcpy + one C++ normal pass, vs 300–700 ms of GDScript emission.
func _build_fast(fids: PackedInt32Array) -> Mesh:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): the tri-order UV/UV2 arrays, grown alongside pos/col ONLY under
	# FP_FACET_TEX (off ⇒ empty + never assigned to the surface → byte-identical mesh format).
	var tex := _tex_on()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for fid in fids:
		# COSMOS far-ring full coverage (§4): a sunk backstop facet cannot ride the pre-triangulated memcpy (its
		# vertices are pushed radially inward per-vertex at BACKSTOP_CELLS). Under FULL_COVER it falls back to the
		# per-vertex sunk expansion (a handful of facets — §5); non-backstop facets keep the memcpy fast path. The
		# vertex order/winding matches _emit_cached exactly, so the later global generate_normals is bit-identical.
		if _emit_dense(fid):   # FP_MID_DENSE: backstop ∪ ready mid-dense → the dense sunk expansion (off the memcpy fast path)
			_append_backstop_tris(pos, col, fid, uv, uv2)
		elif _is_limb_dense(fid):   # COSMOS PLANET-VIEW §3 (B): a limb facet → the dense un-sunk expansion (off the memcpy fast path)
			_append_limb_tris(pos, col, fid, uv, uv2)
		else:
			_ensure_tri_cached(fid)
			pos.append_array(_tri_pos_cache[fid])
			col.append_array(_tri_col_cache[fid])
			if tex:
				uv.append_array(_tri_uv_cache[fid])
				# COSMOS LOD-TEXTURE Phase 4: the close-up slot is DYNAMIC (LRU per emit axis), so the fast path
				# cannot ride the permanent (face,-1) uv2 cache once FP_FACET_TEX_CLOSEUP is on — rebuild the 96 uv2s
				# inline with this rebuild's slot (face is stable, .y = current layer or -1). Off ⇒ the cached (face,-1)
				# append verbatim (byte-identical to Phase 1). Cheap: 96 pushes/facet, only under the close-up flag.
				# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): the whole per-rebuild
				# override retires — `_ensure_tri_cached` already baked the STABLE fid into `_tri_uv2_cache[fid]`
				# forever (LAW S: geometry never needs to change when a slot moves), so the permanent cache is always
				# correct and the CU-specific rebuild above would just recompute the identical value at a cost.
				if _cu_on() and not CubeSphere.FP_SLOT_INDIRECT:
					var face: int = _tex_decode(fid)[0]
					var sv := Vector2(float(face), _slot_of(fid))
					var cu2: PackedVector2Array = _tri_uv2_cache[fid].duplicate()
					for i in range(cu2.size()):
						cu2[i] = sv
					uv2.append_array(cu2)
				else:
					uv2.append_array(_tri_uv2_cache[fid])
	if pos.size() == 0:
		return ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = col
	if tex:
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
	var flat := ArrayMesh.new()
	flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)   # normal-less; positions + colors only
	var st := SurfaceTool.new()
	st.create_from(flat, 0)                                       # C++ read-back of the vertex list (no GDScript per-vert)
	st.generate_normals()                                        # C++ GLOBAL smoothing — bit-identical to the shipped path
	return st.commit()

## FP-S1(d) gate helper: synchronously complete a pending deferred rebuild (what _process does over budgeted frames)
## so headless gates — which do not step frames — can assert the post-crossing visible set. COSMOS-PERF STEP 2: joins
## any in-flight off-thread build first (so the caches are quiescent), then rebuilds synchronously — force_rebuild is
## always immediate + main-thread, regardless of the async flag.
func force_rebuild() -> void:
	_join_async_rebuild()
	_emit_cached_only = false        # S1b: force_rebuild always emits the FULL front set (warms as needed) — gate + set_excluded semantics
	_rebuild_full()

## COSMOS-PERF STEP 2: block until any in-flight worker finishes and discard its result (a synchronous rebuild is about
## to overwrite it). Called before force_rebuild/set_excluded (which rebuild inline) and on _exit_tree (the worker reads
## this node's caches — it must not outlive the node). No-op when nothing is in flight.
func _join_async_rebuild() -> void:
	if not _async_building:
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## COSMOS-PERF STEP 2: never free while a worker is still reading our caches.
func _exit_tree() -> void:
	_join_async_rebuild()

# --- T2e far-ring build/swap timing events ---
## Push one rebuild's timing record. `path` = "sync"|"async"; build_ms = mesh assembly (off-thread for async), swap_ms =
## the main-thread RID create/instance update, verts = the committed vertex count. Main-thread only in both paths.
func _push_event(path: String, build_us: int, swap_us: int, verts: int) -> void:
	_events.append({
		"type": "farring", "path": path,
		"build_ms": snappedf(float(build_us) / 1000.0, 0.01),
		"swap_ms": snappedf(float(swap_us) / 1000.0, 0.01),
		"verts": verts,
	})
	while _events.size() > EVENTS_MAX:
		_events.pop_front()   # NEVER-OOM: drop the oldest if no bridge is draining

## Drain the pending far-ring timing records (FIFO), clearing the queue. WorldManager.take_farring_events() delegates here.
func take_events() -> Array:
	if _events.is_empty():
		return []
	var out := _events
	_events = []
	return out

# --- gate diagnostics ---
func is_rebuild_pending() -> bool: return _pending
func reemit_count() -> int: return _reemit_count
func snapshot_count() -> int: return _snapshot_count            # FIX A2 (G-SHELL-FALLHOLD): scheduled re-emits — flat during a held fall
func warm_fail_count() -> int: return _warm_fail_count          # FIX D (G-WARM-TRUE-BUDGET): sh_wfail — must FLATLINE once the warm converges
func warm_front_step(nrm: Array, thresh: float) -> bool: return _warm_front_step(nrm, thresh)   # FIX D: gate driver entry
func is_emitted(fid: int) -> bool: return _emitted.has(fid)
func emitted_count() -> int: return _emitted.size()
func is_backstop(fid: int) -> bool: return _is_backstop(fid)     # COSMOS far-ring full coverage — gate visibility
func backstop_cache_size() -> int: return _bpos_cache.size()     # G-FRC-BOUND: dense caches ≤ 5-facet bound
func is_emitted_backstop(fid: int) -> bool: return _emitted_backstop.has(fid)   # TIER-DEPTH P1: fid drawn SUNK in the committed mesh
func is_sticky(fid: int) -> bool: return _sticky.has(fid)        # TIER-DEPTH P1 gate visibility
func sticky_count() -> int: return _sticky.size()               # TIER-DEPTH P1: sticky set ≤ STICKY_RING1_MAX bound
# COSMOS-ORBITAL-SHELL S1/S2 gate visibility
func shell_cam_set() -> bool: return _cam_set                   # is the camera-set law currently governing the emit set
func shell_emit_axis() -> Array: return _emit_axis              # ĉ (ABSOLUTE): the current emit cull axis
## COSMOS LOD-TEXTURE Phase 4: the driver's off-surface decision (camera-set + not floored) — WorldManager gates the
## close-up promotion on this (the close-up tier is an off-surface / orbit-approach feature; on-surface it stays base map).
func shell_offsurface() -> bool: return _cam_set and not _emit_floored_last
## COSMOS TEXTURED-LOD V4 (FP_SKIN_SSE): the camera's scale-correct distance from the body centre (blocks), computed each
## frame by apply_camera_set. WorldManager forwards it to FacetTexBaker.update so the screen-space promotion law can size a
## facet's on-screen blocks. 0 until the camera-set driver has run ⇒ the baker's SSE law falls back to the regime path.
func shell_cam_dist() -> float: return _dbg_d
func shell_emit_cos() -> float: return _emit_cos                # cos(θ_emit): the current emit threshold
func coarse_cache_size() -> int: return _pos_cache.size()       # S2: how many facets' coarse caches are warmed (prewarm ≤ 6·K²)
func prewarm_cursor() -> int: return _prewarm_cursor            # S2: prewarm progress (≥ 6·K² ⇒ one-shot complete)

## COSMOS-ORBITAL-SHELL live-path telemetry (remote_bridge streams this) — disambiguates the driver→warm→emit→draw
## chain the direct-call gates never exercised. Returns {} when the camera-set law is NOT engaged (flag off / never
## driven) so a shipped/flag-off build stamps NOTHING (byte-identical telemetry). Fields:
##  sh_cam       camera-set law engaged
##  sh_emit      emitted facet count (H-A: small/stuck; H-B: ~= visN but the far side is still blank ⇒ a DRAW problem)
##  sh_visN      front-visible target count under the current axis (what SHOULD be emitted)
##  sh_cachedN   how many of the target are cache-ready right now (H-A: cachedN << visN ⇒ warm/prewarm is the bottleneck)
##  sh_cached / sh_bcached / sh_prewarm   coarse+dense cache fill + the one-shot prewarm cursor (→ 6·K² = complete)
##  sh_off / sh_dwell / sh_pend / sh_build   driver arming + pipeline state
##  sh_reemit / sh_begin / sh_wpass / sh_wfail   re-emit + begin_rebuild counts + warm pass/fail (H-A: wfail≫0, begin≈0)
##  sh_axdot     dot(_emit_axis, true sub-camera dir) — ~1 aligned; low/negative ⇒ H-C (wrong emit hemisphere)
##  sh_theta / sh_d / sh_h / sh_scale   θ_emit(deg), distance, altitude, SN3 clamp scale (H-B far-plane/placement signal)
func shell_telemetry() -> Dictionary:
	if not _cam_set:
		return {}
	var p := _cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var visN := 0
	var cachedN := 0
	var k := FacetAtlas.K
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if _front_visible(fid, nrm, thresh):
					visN += 1
					if _emit_cache_ready(fid):
						cachedN += 1
	var axdot: float = _emit_axis[0] * _dbg_true_dir[0] + _emit_axis[1] * _dbg_true_dir[1] + _emit_axis[2] * _dbg_true_dir[2]
	# REVISION 7 (FP_SMOOTH_SLOT_MESH): surface the slot-mesh commit stats so a live A/B can confirm the path is
	# ACTIVE (smooth_slot_path=1, not refused-to-fallback) and the per-frame commit cost (smooth_commit_ms) replaced
	# the O(N²) whole-tier upload spike. Empty dict (0/absent) with the flag off or _smooth unbuilt.
	var _sms: Dictionary = (_smooth.slot_mesh_stats() if (_smooth != null and _smooth.has_method("slot_mesh_stats")) else {})
	# FP_SMOOTH_TILE_SURF: per-tile draw-call impact — smooth_tile_nodes is the live draw count from per-tile
	# MeshInstances during the warmup fill (peaks then settles to ~0 as tiers consolidate); the KEY live signal for
	# whether the consolidate-at-settle pacing keeps steady-state draws bounded on gl_compat.
	var _tss: Dictionary = (_smooth.tile_surf_stats() if (_smooth != null and _smooth.has_method("tile_surf_stats")) else {})
	return {
		"sh_cam": _cam_set,
		"smooth_v2_res": (_smooth_v2.resident_count() if _smooth_v2 != null else 0),        # FP_SMOOTH_V2: resident annulus tiles
		"smooth_v2_commit_ms": (_smooth_v2.commit_ms() if _smooth_v2 != null else 0.0),      # FP_SMOOTH_V2: last whole-surface ArrayMesh rebuild ms
		"smooth_res": (_smooth.resident_count() if _smooth != null else 0),   # FP_FAR_SMOOTH: committed smooth tiles
		"smooth_slot_path": int(_sms.get("smooth_slot_path", 0)),             # 1=slot-mesh region-writes active, 0=off/refused-fallback
		"smooth_commit_ms": float(_sms.get("smooth_commit_ms", 0.0)),         # main-thread ms in slot commits this frame
		"smooth_upload_kb": float(_sms.get("smooth_upload_kb", 0.0)),         # KB region-written this frame
		"smooth_commit_defer": int(_sms.get("smooth_commit_defer", 0)),       # whole commit-events still queued (budget deferral)
		"smooth_tile_nodes": int(_tss.get("smooth_tile_nodes", 0)),           # FP_SMOOTH_TILE_SURF: live per-tile MeshInstance draw count
		"smooth_tile_surf_path": int(_tss.get("smooth_tile_surf_path", 0)),   # 1=per-tile path has run this session
		"smooth_drive_ms": _dbg_drive_ms,                                     # REV7 diag: ms/frame in _smooth_drive (rank+request+step)
		"smooth_step_ms": _dbg_step_ms,                                       # REV7 diag: ms/frame in _smooth.step() alone (mesh commit)
		"env_converge_ms": _dbg_env_ms,                                       # REV7 diag: ms/frame in _surface_converge_emit
		"sh_emit": _emitted.size(),
		"sh_visN": visN,
		"sh_cachedN": cachedN,
		"sh_cached": _pos_cache.size(),
		"sh_envN": _env_done.size(),   # FP_ENV_FALLBACK_EMIT: facets truly enveloped (vs chord fallback) — live upgrade convergence
		"sh_benvN": _benv_done.size(), # FP_ENV_FLOORED_ASYNC: DENSE facets truly enveloped (vs full-sink chord) — floored upgrade convergence
		"sh_bcached": _bpos_cache.size(),
		"sh_prewarm": _prewarm_cursor,
		"sh_off": _offsurface,
		"sh_dwell": snappedf(_offsurface_dwell, 0.1),
		"sh_pend": _pending,
		"sh_build": _async_building,
		"sh_reemit": _reemit_count,
		"sh_begin": _begin_rebuild_count,
		"sh_wpass": _warm_pass_count,
		"sh_wfail": _warm_fail_count,
		"sh_axdot": snappedf(axdot, 0.001),
		"sh_theta": snappedf(_dbg_theta_emit_deg, 0.1),
		"sh_d": snappedf(_dbg_d, 0.1),
		"sh_h": snappedf(_dbg_h, 0.1),
		"sh_scale": snappedf(_dbg_scale, 0.0001),
	}

## COSMOS FS1 gate (G-SHELL-WELD): the horizon (CELLS) ABSOLUTE positions for facet `fid` — warms + returns the cache.
func horizon_positions(fid: int) -> PackedVector3Array:
	_ensure_cached(fid)
	return _pos_cache[fid]

## TIER-DEPTH P2 gate: the SUNK (as-rendered) dense backstop vertex positions for facet `fid` — the cache (envelope or
## constant-relief) pushed in by the current emit sink (TierPlace.backstop_sink). The gate projects these onto the near
## height field (world_to_lattice64) to prove the rendered coarse surface never rises above the near block tops.
func backstop_rendered_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _sunk_positions(_bpos_cache[fid])

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 gate (G-NF-HEIGHT): the fid-AWARE twin of the above — reproduces
## EXACTLY the sink choice the live SYNCHRONOUS emit path uses for `fid` (including LAW R-D's reduced interim
## ε-sink for a rim-eligible, not-yet-S2-committed facet). `backstop_rendered_positions` above is kept fid-agnostic
## (always the plain full sink) so every gate written against it before this revision is unmoved. `rim_on` defaults
## to the `FP_SMOOTH_RIM` const (the gate passes `true` explicitly to exercise the R-D branch without sed).
func backstop_rendered_positions_live(fid: int, rim_on := CubeSphere.FP_SMOOTH_RIM) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _sunk_positions(_bpos_cache[fid], fid, rim_on)

## NO-PROTRUSION G-NPT gate: the AS-RENDERED coarse-horizon vertex grid for facet `fid`. Under FP_ENV_ALL the coarse
## `_pos_cache` carries min-envelope heights AND the emit path sinks it by the ε guard (the coarse twin of the
## backstop sink), so this returns the same ε-sunk surface the live emit draws; with the flag off it returns the
## shipped raw exact-chord `_pos_cache` (what the un-enveloped horizon really renders — where R-A/R-B protrude).
func horizon_rendered_positions(fid: int) -> PackedVector3Array:
	_ensure_cached(fid)
	if TierPlace.env_all_on():
		return _sunk_positions(_pos_cache[fid])
	return _pos_cache[fid]

## TIER-DEPTH P2 gate: the RAW (un-sunk) dense backstop cache for facet `fid` — the ENVELOPE heights under FP_TIER_ENVELOPE,
## the plain profile_at_dir relief otherwise. The gate applies its OWN fixed ε sink to this so it can prove the ENVELOPE
## property in isolation (a lower bound at a small sink) vs the plain sample (which needs the full 6-block sink to hold).
func backstop_raw_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _bpos_cache[fid]

# FP_ENV_FALLBACK_EMIT: build a facet's CHEAP exact-chord WELD arrays (the shipped pre-FP_ENV_ALL coarse surface,
# CELLS=4, ~25 profile samples) — ~300× cheaper than the env envelope build. Shared by the FP_SHELL_WELD coarse path
# above and by _ensure_chord_cached (the orbit fallback). Pure sampling; no cache/scene touch.
func _weld_chord_arrays(fid: int) -> Array:
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var stride := CELLS + 1
	for gj in range(stride):
		for gi in range(stride):
			_weld_node(cd, float(gi) / float(CELLS), float(gj) / float(CELLS), pos, col)
	return [pos, col]

# FP_ENV_FALLBACK_EMIT: ensure facet `fid` has SOME coarse cache to emit — the cheap exact-chord weld — WITHOUT
# marking `_env_done`, so the orbit warm still upgrades it to the min-envelope later (erase + _ensure_cached in the
# worker). Keeps orbit coverage structural (never a black hole) while the ~300×-heavier env build streams in behind.
# Only ever called under the env_all + async + fallback regime (pure orbit — no near terrain for a chord to poke).
func _ensure_chord_cached(fid: int) -> void:
	if _pos_cache.has(fid):
		return
	var a := _weld_chord_arrays(fid)
	_pos_cache[fid] = a[0]
	_col_cache[fid] = a[1]

# Compute + cache facet `fid`'s ABSOLUTE-coord terrain quad once (built from its planarized corners + radial relief).
# REVISION 5 Stage B: `force` skips the "already cached" early-return and REPLACES `_pos_cache[fid]`/`_col_cache[fid]`
# via a single in-place assignment (never erases first) — the hygiene fix for the worker's chord→envelope upgrade
# (a concurrent main-thread reader can no longer observe a momentarily-missing key). `env_on`/`fallback_on` override
# `TierPlace.env_all_on()`/`CubeSphere.FP_ENV_FALLBACK_EMIT` (gate-forcing convention); every real caller passes at
# most `force` ⇒ byte-identical.
func _ensure_cached(fid: int, force := false, env_on := TierPlace.env_all_on(), fallback_on := CubeSphere.FP_ENV_FALLBACK_EMIT) -> void:
	if _pos_cache.has(fid) and not force:
		return
	# NO-PROTRUSION §0.3 (FP_ENV_ALL): the coarse HORIZON cache (R-A / R-B) becomes a min-envelope LOWER BOUND too —
	# every CELLS=4 vertex placed radially at env(v) = min near g over its dilated footprint, with EDGE-CANON on the
	# shared boundary so it still welds. Requires FP_SHELL_WELD (checked in env_all_on) — the enveloped surface is a
	# pure radial field. Textually separate so the flag-off path below is byte-identical.
	if env_on:
		var g := _env_weld_grid(fid, CELLS)
		_pos_cache[fid] = g[0]
		_col_cache[fid] = g[1]
		if fallback_on:
			_env_done[fid] = true    # this coarse cache IS the min-envelope (not a chord fallback)
		return
	# COSMOS FS1 (§4.1): the WELD path emits every vertex RADIALLY from the SHARED cube-sphere corner dirs, so a
	# facet's edge welds bit-identically to its neighbour's (One-Surface Law). Textually separate from the shipped
	# planar-corner path so flag-off is byte-identical.
	if CubeSphere.FP_SHELL_WELD:
		# CELLS is the coarse resolution — the coarse-owns-edge snap is a no-op here (cstride==1).
		var a := _weld_chord_arrays(fid)
		_pos_cache[fid] = a[0]
		_col_cache[fid] = a[1]
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := CELLS + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE (node placed by transform)
			# far water iff g < SEA_LEVEL — STRICT, matching near's sea fill (g < y <= SEA_LEVEL, so g==SEA_LEVEL is DRY
			# beach/shelf sand, not water). `<=` painted the flattened beach shelf (a wide band quantized to g==SEA_LEVEL)
			# as water over near's sand. Matches the already-correct far_mesh_builder.gd classifier.
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_pos_cache[fid] = pos
	_col_cache[fid] = col

## COSMOS far-ring full coverage (§4): ensure the emit cache appropriate to facet `fid`'s CURRENT role — the dense
## backstop cache for a backstop facet under FULL_COVER, else the shipped CELLS grid. Called by every synchronous
## assembler path before it emits; the async path warms these on the main thread in _warm_front instead.
func _ensure_emit_cached(fid: int) -> void:
	# FP_ENV_FLOORED_ASYNC: the SYNC assembler (force_rebuild / crossings) must NOT env-build inline on the ground — one
	# _ensure_cached env build is 16-40ms and force_rebuild touches the whole front (a multi-second stall under env_all).
	# Build the CHEAP chord instead (dense chord = full-sink, coarse chord = ε-sunk); the worker upgrades env behind.
	if _env_async_floored_on():
		if _dense_warm(fid):
			_ensure_backstop_chord_cached(fid)
		else:
			_ensure_chord_cached(fid)
		return
	if _dense_warm(fid):   # FP_MID_DENSE: backstop ∪ mid-dense disc build the dense cache (sync assembler path)
		_ensure_backstop_cached(fid)
	else:
		_ensure_cached(fid)

## COSMOS far-ring full coverage (§3): compute + cache facet `fid`'s DENSE (BACKSTOP_CELLS) ABSOLUTE-coord terrain quad
## once. Identical construction to _ensure_cached (planar corners + radial relief + FarPalette colour) but at the denser
## resolution so the between-sample chord error stays below the near mountain relief. The BACKSTOP_SINK radial push is
## NOT baked here — it is applied per emitted vertex (so the cache is role-agnostic and survives a crossing unchanged).
# FP_ENV_FLOORED_ASYNC: build the CHEAP dense CHORD cache (the pre-envelope BACKSTOP_CELLS weld, ~289 profile calls)
# WITHOUT marking `_benv_done` — so the floored path draws a dense target SUNK immediately (full-sink, never poking
# through near terrain) while the ~16-40ms dense ENVELOPE upgrade streams in on the worker. Requires FP_SHELL_WELD
# (env_all_on already requires it). Mirrors _ensure_chord_cached one tier up. Only called under the floored regime.
func _ensure_backstop_chord_cached(fid: int) -> void:
	if _bpos_cache.has(fid):
		return
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			_weld_node(cd, float(gi) / float(cells), float(gj) / float(cells), pos, col)
	_weld_snap_edges(pos, cells)
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 (FP_FARRING_UNCOVERED_TRUE): backstop facet `fid`'s plain welded TRUE
## chord — the height source for the per-vertex analytic un-sink. Construction is a byte-for-byte mirror of
## `_ensure_backstop_chord_cached` above (SAME shared corner dirs, SAME weld + edge-snap), kept in the SEPARATE
## `_btrue_cache` because under env_all `_bpos_cache` holds the ENVELOPE-MIN heights (a deliberate lower bound),
## not the true surface — conflating the two would poison the no-protrusion proof elsewhere in this file. Pure
## CPU + const reads only (facet geometry + worldgen profile) — safe to call from the async worker exactly like
## `_ensure_backstop_chord_cached` already is (via `_env_build_one`). Built lazily, once per fid; never forced —
## the true chord is terrain-invariant so it can never go stale.
func _ensure_backstop_true_cached(fid: int) -> void:
	if _btrue_cache.has(fid):
		return
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()   # discarded — _btrue_cache carries no colour, _bcol_cache is reused at emit
	for gj in range(stride):
		for gi in range(stride):
			_weld_node(cd, float(gi) / float(cells), float(gj) / float(cells), pos, col)
	_weld_snap_edges(pos, cells)
	_btrue_cache[fid] = pos

## COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 — is the ABSOLUTE surface point `surface_pt` OUTSIDE the streamed
## VoxelViewer ellipsoid (inflated by UNSINK_MARGIN_BLOCKS on every axis)? `params` = (r, O, H) from
## TerrainConfig.streamed_ellipsoid_params() by default — a PARAMETER (not a direct read) so a headless gate can
## drive the real law against a SYNTHETIC ellipsoid without sed-toggling FACETED (mirrors this file's existing
## "force via function param" convention, e.g. `_sunk_positions`'s `rim_on`). `have_col=false` (no real column
## pushed yet) ⇒ always covered — a not-yet-known player position must never spuriously un-sink the whole ring.
## Pure: reads only its arguments + the UNSINK_MARGIN_BLOCKS const — safe on the async worker.
## Ellipsoid test: centre = col + up·O (up = col's own radial direction — the planet centre is the ABSOLUTE
## origin, so "up" at the player IS col.normalized()); decompose (surface_pt − centre) into its radial component
## (along up) and tangential component (the remainder); OUTSIDE iff (radial/(H+margin))² + (tangential/(r+margin))² > 1.
func _uncovered(surface_pt: Vector3, col: Vector3, have_col: bool, params: Vector3 = TerrainConfig.streamed_ellipsoid_params()) -> bool:
	if not have_col:
		return false
	var r := params.x + CubeSphere.UNSINK_MARGIN_BLOCKS
	var h := params.z + CubeSphere.UNSINK_MARGIN_BLOCKS
	if r <= 0.0 or h <= 0.0:
		return true   # a degenerate ellipsoid covers nothing — never divide by zero
	var cl := col.length()
	var up := (col / cl) if cl > 0.001 else Vector3.UP
	var delta := surface_pt - (col + up * params.y)
	var radial := delta.dot(up)
	var tangential := (delta - up * radial).length()
	var nr := radial / h
	var nt := tangential / r
	return (nr * nr + nt * nt) > 1.0

## COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 — blend the per-vertex analytic un-sink over `covered_pos` (whichever
## envelope+sink / noblack law the caller already resolved for facet `fid`): an UNCOVERED vertex (its TRUE chord
## point lies outside the inflated ellipsoid — near mesh can never reach it) takes the TRUE height; a COVERED
## vertex keeps `covered_pos` BYTE-IDENTICALLY (the proven no-protrusion regime is untouched wherever near/far can
## actually coexist). Frontier continuity: every vertex is a full grid slot taking ONE of the two heights (never
## interpolated) — a mixed cell simply spans them, and under FP_BLOCKY_FARRING the cell top is the corner MIN, so
## a mixed frontier cell automatically takes the conservative (covered/sunk) height. Pure w.r.t. its arguments
## (`col`/`have_col` already resolved by the caller from the correct live-vs-frozen source) — safe on the worker.
func _blend_uncovered(covered_pos: PackedVector3Array, fid: int, col: Vector3, have_col: bool,
		params: Vector3 = TerrainConfig.streamed_ellipsoid_params()) -> PackedVector3Array:
	_ensure_backstop_true_cached(fid)
	var tp: PackedVector3Array = _btrue_cache[fid]
	var out := PackedVector3Array()
	out.resize(covered_pos.size())
	for i in range(covered_pos.size()):
		var t: Vector3 = tp[i]
		out[i] = t if _uncovered(t, col, have_col, params) else covered_pos[i]
	return out

# REVISION 5 Stage B: `force` skips the "already cached" early-return and REPLACES `_bpos_cache[fid]`/`_bcol_cache[fid]`
# via a single in-place assignment (never erases first — see `_ensure_cached`'s matching note). `env_on`/`floored_on`
# override `TierPlace.envelope_on() or TierPlace.env_all_on()`/`CubeSphere.FP_ENV_FLOORED_ASYNC`; every real caller
# passes at most `force` ⇒ byte-identical.
func _ensure_backstop_cached(fid: int, force := false, env_on := TierPlace.envelope_on() or TierPlace.env_all_on(), floored_on := CubeSphere.FP_ENV_FLOORED_ASYNC) -> void:
	if _bpos_cache.has(fid) and not force:
		return
	# TIER-DEPTH P2 (§5.1): under the min-envelope rule each vertex height becomes a PROVABLE lower bound of the near
	# surface over its dilated footprint, replacing the constant sink. Separate builder so the flag-off path is textually
	# the shipped per-vertex profile sample (byte-identical).
	if env_on:
		_ensure_backstop_cached_env(fid)
		if floored_on:
			_benv_done[fid] = true    # this dense cache IS the min-envelope (not a full-sink chord fallback)
		return
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	# COSMOS FS1 (§4.1/§4.2): radial weld from shared corner dirs + the coarse-owns-edge T-junction (the dense
	# BACKSTOP_CELLS outer ring is snapped onto the CELLS=4 coarse chord so it welds a horizon 4-edge crack-free).
	if CubeSphere.FP_SHELL_WELD:
		var cd := FacetAtlas.facet_corner_dirs(fid)
		for gj in range(stride):
			for gi in range(stride):
				_weld_node(cd, float(gi) / float(cells), float(gj) / float(cells), pos, col)
		_weld_snap_edges(pos, cells)
		_bpos_cache[fid] = pos
		_bcol_cache[fid] = col
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, un-sunk
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## TIER-DEPTH P2 (§5.1): the MIN-ENVELOPE dense backstop cache. Each of the (BACKSTOP_CELLS+1)² coarse vertices keeps its
## own planar position b and radial direction d̂ (grid unchanged — NOT a re-mesh), but its HEIGHT becomes a provable lower
## bound of the near surface: the MINIMUM near g over the vertex's 2×2-coarse-cell footprint DILATED by the radial-vs-
## normal skew reach, sampled on a fine grid at ENV_FINE_MULT × the coarse resolution. A rendered backstop triangle is a
## convex combination of three such corner minima, so it stays ≤ the near surface everywhere in the overlap BY
## CONSTRUCTION (no tuned constant — the proof). The small radial ε sink at emit (TierPlace.backstop_sink) covers the
## sub-fine-sample residual + f32 rounding. Colour is the vertex's OWN direct biome/water sample (cosmetic). Costs
## ~(ENV_FINE_MULT·cells+1)² transient profile_at_dir samples at cache build; ZERO persistent bytes (same 17² grid). Uses
## the far ring's own profile_at_dir funnel (byte-equal to sample_columns by the one-sampler law), so no facet-param→
## lattice remap is introduced. NEVER-OOM: the fine grid is transient and bounded; no cache grows with walk distance.
func _ensure_backstop_cached_env(fid: int) -> void:
	# COSMOS FS1 (§4): the WELD path — fine near-g grid sampled along the SHARED corner dirs, each coarse vertex
	# placed RADIALLY at the min-envelope height, outer ring snapped to the coarse chord. env(i) ≤ direct g, so an
	# env backstop always sits AT-OR-BELOW a welded horizon neighbour (no see-through); env↔env welds exactly.
	if CubeSphere.FP_SHELL_WELD:
		_ensure_backstop_cached_env_weld(fid)
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Fine near-g grid over the facet (pitch = edge/fine ≈ 3 blocks): one profile_at_dir per fine node.
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var s := float(fi) / float(fine)
			var t := float(fj) / float(fine)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var prof := TerrainConfig.profile_at_dir(bx / ln, by / ln, bz / ln, FacetAtlas.R_BLOCKS)
			fg[fj * fstride + fi] = int(prof.x)
	# Skew dilation, in fine-sample units: the far vertex lands displaced ≤ ENV_DILATE_BLOCKS from its footprint b.
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	var dil := int(ceil(TierPlace.ENV_DILATE_BLOCKS / maxf(fine_pitch, 0.001)))
	var half := mult + dil                       # footprint = ±1 coarse cell (±mult fine) + the skew dilation
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var fic := gi * mult
			var fjc := gj * mult
			var gmin := 1 << 30
			for wj in range(fjc - half, fjc + half + 1):
				if wj < 0 or wj >= fstride:
					continue
				var rowoff := wj * fstride
				for wi in range(fic - half, fic + half + 1):
					if wi < 0 or wi >= fstride:
						continue
					var gg: int = fg[rowoff + wi]
					if gg < gmin:
						gmin = gg
			var relief := maxf(0.0, float(gmin - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, envelope height, un-sunk
			var vp := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## COSMOS FS1 (§4) — the WELD twin of _ensure_backstop_cached_env: identical min-envelope construction, but every
## direction comes from the SHARED corner dirs and every vertex is placed RADIALLY (d̂·(R+relief)), then the outer
## ring is snapped to the coarse chord. Kept a separate function so the shipped envelope path stays byte-identical.
func _ensure_backstop_cached_env_weld(fid: int) -> void:
	# NO-PROTRUSION §0.3 (FP_ENV_ALL): the dense backstop shares the SAME EDGE-CANON boundary rule as the coarse
	# horizon cache so the two tiers weld to each other (coarse-index boundary/corner values coincide). The shipped
	# FP_TIER_ENVELOPE-only path (plain 2-D footprint below) is left byte-identical — this branch only runs under env_all.
	if TierPlace.env_all_on():
		var g := _env_weld_grid(fid, CubeSphere.BACKSTOP_CELLS)
		_bpos_cache[fid] = g[0]
		_bcol_cache[fid] = g[1]
		return
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Fine near-g grid over the facet, sampled along the shared corner dirs (one profile_at_dir per fine node).
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var d := _weld_unit(cd, float(fi) / float(fine), float(fj) / float(fine))
			fg[fj * fstride + fi] = int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS).x)
	# Skew dilation (identical derivation to the shipped env builder).
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	var dil := int(ceil(TierPlace.ENV_DILATE_BLOCKS / maxf(fine_pitch, 0.001)))
	var half := mult + dil
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var d := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
			var fic := gi * mult
			var fjc := gj * mult
			var gmin := 1 << 30
			for wj in range(fjc - half, fjc + half + 1):
				if wj < 0 or wj >= fstride:
					continue
				var rowoff := wj * fstride
				for wi in range(fic - half, fic + half + 1):
					if wi < 0 or wi >= fstride:
						continue
					var gg: int = fg[rowoff + wi]
					if gg < gmin:
						gmin = gg
			pos.append(_weld_place(d, gmin))                     # ABSOLUTE, radial, envelope height, un-sunk
			var vp := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_weld_snap_edges(pos, cells)
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

# =====================================================================================================
# NO-PROTRUSION §0.3 (FP_ENV_ALL) — the GLOBAL ENVELOPE HEIGHT LAW builder, shared by the coarse horizon cache
# (cells=CELLS) and the dense backstop cache (cells=BACKSTOP_CELLS). Every vertex is placed RADIALLY from the
# shared corner dirs at a min-envelope height env(v) = min{ near g over v's dilated footprint }, so a rendered
# triangle (a convex combination of three vertex lower bounds) stays ≤ the true surface. Boundary vertices use
# the EDGE-CANON rule — their footprint is derived ONLY from the SHARED edge data at a resolution-INDEPENDENT
# canonical pitch/reach — so a coarse facet and an adjacent dense facet compute the SAME value at a shared
# corner/coarse-index edge node ⇒ the shell still welds (FP_SHELL_WELD preserved). Interior vertices use the
# cheap pre-sampled 2-D fine grid. The ε sink is applied at EMIT (not baked) so the raw caches keep welding
# (horizon_positions / backstop_raw_positions coincide). Returns [pos, col]; the caller stores into the right cache.
# STATIC (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3): no instance state is read — made static (with its whole
# `_weld_unit`/`_weld_place`/`_weld_snap_edges`/`_env_node_min`/`_env_corner_min`/`_env_edge_min` call chain, same
# reasoning) so `FacetSmoothTier.build_tile_rim` (the S2 near-collar builder, a different RefCounted with no ring
# instance) can call it directly — "reuse the shipped envelope law, don't reinvent it" (§3 P3). Existing call sites
# (unqualified within this class, `ring._env_weld_grid(...)` from the gate) are unaffected: GDScript resolves a
# static method through an instance reference identically to an instance method call.
# =====================================================================================================
## `mult_override` (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D, FP_RIM_CHEAP): when > 0, use THIS fine-
## sample multiplier instead of the shipped `TierPlace.ENV_FINE_MULT` — the S2 near-collar builder's ONLY caller
## (`FacetSmoothTier.build_tile_rim`) passes `TierPlace.rim_fine_mult()` under the flag to cut the ~174k
## `profile_at_dir` samples/facet that drive the warmup allocator-convoy spike (R5.3). Every other call site (the
## coarse-horizon/dense-backstop caches) omits it — default -1 reproduces the shipped `TierPlace.ENV_FINE_MULT`
## verbatim, byte-identical.
static func _env_weld_grid(fid: int, cells: int, mult_override: int = -1) -> Array:
	# FP_ENV_WARM_ASYNC telemetry: attribute this (heavy) build to its thread, so the relocation is provable — OFF the
	# builds land on MAIN; ON they land on the far-ring worker while env_build_main stays frozen. Cheap thread-id compare.
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		env_build_main += 1
	else:
		env_build_worker += 1
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var stride := cells + 1
	var cstride := cells / CELLS                       # 1 for the coarse facet, BACKSTOP_CELLS/CELLS for the dense one
	var mult := mult_override if mult_override > 0 else TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Pre-sample the fine near-g grid along the SHARED corner dirs (interior 2-D footprint source; one profile per node).
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var d := _weld_unit(cd, float(fi) / float(fine), float(fj) / float(fine))
			fg[fj * fstride + fi] = int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS).x)
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	# The RADIAL-vs-NORMAL skew: a far vertex placed radially at height h projects along the near n̂ onto a column
	# displaced by ≈ h·tan(α), α ≤ the facet half-diagonal — up to ~relief·0.046 ≈ 6-8 blocks on a high mountain, and
	# MORE than the shipped ENV_DILATE_BLOCKS(6) covers (measured raw residual +6.2 at dilation 6 ⇒ the min missed
	# the truly-overlaid column). env_all dilates the footprint by a generous rescale-safe skew allowance (~0.3 of a
	# coarse cell ≈ 31 blocks at R=6371, covering relief up to ~650) so the min ALWAYS includes the projected column
	# ⇒ raw residual < ε. Env_all-LOCAL (does not touch the shipped ENV_DILATE_BLOCKS ⇒ FP_TIER_ENVELOPE unmoved).
	var skew := edge_blocks / float(CELLS) * 0.3
	var dil := int(ceil(skew / maxf(fine_pitch, 0.001)))
	var half := mult + dil                             # interior footprint = ±1 own-cell (±mult fine) + skew dilation
	# CANONICAL (resolution-independent) edge/corner extents: reach = 1 coarse (CELLS) cell + the skew allowance
	# (covers a boundary node's incident triangles on BOTH facets + the projected column); pitch derived from the
	# FINEST reference (BACKSTOP_CELLS) so a coarse and a dense facet sample the same set at a shared node — all fixed
	# constants, identical every facet ⇒ shared boundary/corner values coincide (weld preserved).
	var reach := edge_blocks / float(CELLS) + skew
	# Canonical boundary pitch ≈ half a BACKSTOP cell (~13 blocks): fine enough that the between-sample residual
	# (≈ step²·|h''|/8 ≲ 1 block on the worst mountain facet) stays well under the ε sink (G-NPT-BOUND pins it),
	# yet coarse enough that the disc/band sample counts stay bounded. Fixed constant ⇒ coarse and dense agree.
	var step := edge_blocks / float(2 * CubeSphere.BACKSTOP_CELLS)
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var d := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
			var gmin := _env_node_min(cd, cells, cstride, gi, gj, fg, fstride, mult, half, reach, step)
			pos.append(_weld_place(d, gmin))            # ABSOLUTE, radial, envelope height, un-sunk (ε applied at emit)
			var vp := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_weld_snap_edges(pos, cells)                        # dense: snap fine edge verts onto the EDGE-CANON coarse chord (no-op at CELLS)
	return [pos, col]

## The min near-g over grid node (gi,gj)'s envelope footprint. INTERIOR node → the cheap pre-sampled 2-D fine grid
## (±half). BOUNDARY node → EDGE-CANON (shared-derived, so both facets agree): a CORNER samples a rotationally-
## symmetric disc about the shared corner dir; a COARSE-INDEX edge node samples the shared 1-D edge line + a
## sign-symmetric perpendicular band. A non-coarse-index (fine) edge node falls back to the 2-D footprint because
## `_weld_snap_edges` overwrites it with the coarse chord anyway (so its value never renders).
static func _env_node_min(cd: PackedFloat64Array, cells: int, cstride: int, gi: int, gj: int,
		fg: PackedInt32Array, fstride: int, mult: int, half: int, reach: float, step: float) -> int:
	var on_w := gi == 0
	var on_e := gi == cells
	var on_s := gj == 0
	var on_n := gj == cells
	var nb := int(on_w) + int(on_e) + int(on_s) + int(on_n)
	if nb >= 2:                                         # CORNER — canonical disc about the shared corner dir
		var dc := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
		return _env_corner_min(dc, reach, step)
	if nb == 1:
		var along_idx := gj if (on_w or on_e) else gi
		if along_idx % cstride == 0:                    # coarse-index edge node — canonical line + perp band
			var ca: Vector3
			var cb: Vector3
			var u: float
			if on_s:
				ca = Vector3(cd[0], cd[1], cd[2]); cb = Vector3(cd[3], cd[4], cd[5]); u = float(gi) / float(cells)
			elif on_n:
				ca = Vector3(cd[9], cd[10], cd[11]); cb = Vector3(cd[6], cd[7], cd[8]); u = float(gi) / float(cells)
			elif on_w:
				ca = Vector3(cd[0], cd[1], cd[2]); cb = Vector3(cd[9], cd[10], cd[11]); u = float(gj) / float(cells)
			else:
				ca = Vector3(cd[3], cd[4], cd[5]); cb = Vector3(cd[6], cd[7], cd[8]); u = float(gj) / float(cells)
			return _env_edge_min(ca, cb, u, reach, step)
	# INTERIOR (or a fine edge node that will be snapped): 2-D footprint over the pre-sampled fine grid.
	var fic := gi * mult
	var fjc := gj * mult
	var gmin := 1 << 30
	for wj in range(fjc - half, fjc + half + 1):
		if wj < 0 or wj >= fstride:
			continue
		var rowoff := wj * fstride
		for wi in range(fic - half, fic + half + 1):
			if wi < 0 or wi >= fstride:
				continue
			var gg: int = fg[rowoff + wi]
			if gg < gmin:
				gmin = gg
	return gmin

## EDGE-CANON corner: min near g over a rotationally-symmetric DISC of angular radius reach/R about the shared
## corner dir `d`. The tangent frame is a DETERMINISTIC function of d ONLY (pick the world axis least aligned with
## d, orthonormalize) — so every facet meeting at this corner (any arity) builds the identical sample set ⇒ the
## corner welds. Rings at the canonical pitch, angular samples densified with radius so no dip is missed.
static func _env_corner_min(d: Vector3, reach: float, step: float) -> int:
	var ref := Vector3(0.0, 1.0, 0.0)
	if absf(d.y) >= absf(d.x) and absf(d.y) >= absf(d.z):
		ref = Vector3(1.0, 0.0, 0.0)                    # d ~ ±Y → use X as the reference so the cross is well-conditioned
	var u := (ref - d * ref.dot(d)).normalized()
	var v := d.cross(u).normalized()
	var r := FacetAtlas.R_BLOCKS
	var nr := int(ceil(reach / step))
	var gmin := int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, r).x)   # the corner itself (rad 0)
	for ri in range(1, nr + 1):
		var rad := float(ri) * step
		var na := maxi(6, int(ceil((2.0 * PI * rad) / step)))
		var ainc := (2.0 * PI) / float(na)
		var scale := rad / r                            # angular offset ≈ tan θ for the small facet-scale θ
		for ai in range(na):
			var ang := float(ai) * ainc
			var off := u * (cos(ang) * scale) + v * (sin(ang) * scale)
			var sd := (d + off).normalized()
			var g := int(TerrainConfig.profile_at_dir(sd.x, sd.y, sd.z, r).x)
			if g < gmin:
				gmin = g
	return gmin

## EDGE-CANON edge: min near g over the shared 1-D edge line (param a' ∈ [u±reach] along the corner-dir lerp) × a
## SIGN-SYMMETRIC perpendicular band (±p, p = normalize(edge_dir × radial)). The two facets sharing the edge pass
## the same corner dirs (possibly swapped) and the mirrored parameter (u'=1−u); commutative-add lerp + the ±p / ±off
## symmetry make the sample SET bit-identical either side ⇒ the coarse-index edge nodes weld. Clamped to the edge
## extent [0,1] so a near-corner footprint samples the corner dir (matches the neighbour's clamp — still symmetric).
static func _env_edge_min(ca: Vector3, cb: Vector3, u: float, reach: float, step: float) -> int:
	var edge_dir := cb - ca
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var du := step / edge_blocks
	var r := FacetAtlas.R_BLOCKS
	var np := int(ceil(reach / step))
	var gmin := 1 << 30
	for ia in range(-np, np + 1):
		var ap := clampf(u + float(ia) * du, 0.0, 1.0)
		var d_e := (ca * (1.0 - ap) + cb * ap).normalized()          # = _weld_unit on the edge (bit-identical either side)
		var p := edge_dir.cross(d_e).normalized()                    # in-surface perpendicular (±symmetric across facets)
		for ip in range(-np, np + 1):
			var off := (float(ip) * step) / r
			var sd := (d_e + p * off).normalized()
			var g := int(TerrainConfig.profile_at_dir(sd.x, sd.y, sd.z, r).x)
			if g < gmin:
				gmin = g
	return gmin

## COSMOS far-ring full coverage (§2): return a copy of grid positions `p` pushed radially inward by BACKSTOP_SINK
## blocks (p − p̂·BACKSTOP_SINK) so the coarse backstop sits strictly behind the opaque near voxels. Computed once per
## emit so a shared grid vertex is not re-normalized per triangle. Pure math — safe on the async worker thread.
## `fid` (REVISION 2 LAW R-D, optional): when given AND `rim_on` is true AND `fid` is rim-eligible with no S2 tile
## committed yet, the sink collapses to the small `backstop_sink_rim()` ε-guard instead of the full backstop sink —
## the INTERIM floor before the first S2 commit lands (R.1.d: "FAR renders below NEAR" during streaming). Default
## -1 (no fid) preserves every existing call site byte-identically. `rim_on` defaults to the `FP_SMOOTH_RIM` const
## (mirrors `build_tile`'s `normal_lit` param) so gates can force it via the PARAMETER without sed-toggling the
## compile-time const — the same "poke a flag-gated internal directly" discipline used throughout this codebase.
func _sunk_positions(p: PackedVector3Array, fid: int = -1, rim_on := CubeSphere.FP_SMOOTH_RIM) -> PackedVector3Array:
	# COSMOS TEXTURED-LOD U3 (FP_FARRING_LEVEL): with the U2 cull live (near/far never coexist where covered), the
	# radial sink COLLAPSES from the ~13-block visual sink to the ENV_EPS_G correctness guard — the far ring reads at
	# the near surface's LEVEL. Self-disables to the full sink when the cull is inert (invalid coverage probe). Fringe
	# z-order at the thin un-culled seam rides the shipped FAR_BIAS_K depth bias, not this sink. Off ⇒ full sink verbatim.
	if _level_on():
		return _sunk_positions_amt(p, TierPlace.backstop_sink_level())
	if fid >= 0 and rim_on and _rim_interim_sink_eligible(fid):
		return _sunk_positions_amt(p, TierPlace.backstop_sink_rim())
	return _sunk_positions_amt(p, TierPlace.backstop_sink())   # TIER-DEPTH P2: ε guard under the envelope, else BACKSTOP_SINK

## REVISION 2 LAW R-D: `fid` is rim-eligible (active ∪ live-pool — the facets `_rim_assign` ever S2-assigns) AND has
## not yet had its first S2 tile committed (once it has, this plain backstop plane isn't even drawn for it — the S2
## tile is, via the shared law-6 exclusion — so the reduced sink only matters for the pre-first-commit window).
func _rim_interim_sink_eligible(fid: int) -> bool:
	if not (fid == _active_fid or _excluded.has(fid)):
		return false
	return _smooth == null or int(_smooth.tier_of(fid)) != FacetSmoothTier.S2

# FP_ENV_FLOORED_ASYNC: sink by an EXPLICIT amount — a not-yet-enveloped chord fallback uses the FULL sink
# (backstop_sink_chord) instead of the envelope ε, so it still sits ≤ the near surface until its env upgrade lands.
func _sunk_positions_amt(p: PackedVector3Array, sink: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p.size())
	for i in range(p.size()):
		var v: Vector3 = p[i]
		out[i] = v - v.normalized() * sink
	return out

## COSMOS far-ring full coverage (§4): expand backstop facet `fid`'s dense sunk grid into the tri soup (same two tris
## per cell, same winding, same per-vertex colours as _emit_cached) and append it to the fast path's packed arrays. Used
## only by _build_fast under FULL_COVER for the handful of backstop facets that cannot ride the pre-triangulated memcpy.
func _append_backstop_tris(pos: PackedVector3Array, col: PackedColorArray, fid: int,
		uv: PackedVector2Array = PackedVector2Array(), uv2: PackedVector2Array = PackedVector2Array(),
		uncovered_true_on := CubeSphere.FP_FARRING_UNCOVERED_TRUE) -> void:
	_ensure_backstop_cached(fid)
	# COSMOS FAR-CRUISE NEVER-BLACK: un-sink the sub-camera facet where the near field is absent (true surface, not a
	# sunk well). Off / covered ⇒ the shipped sunk positions (byte-identical).
	var gp: PackedVector3Array
	if uncovered_true_on:
		# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1: SUPERSEDES the whole-facet noblack pick with the per-vertex
		# analytic law. This fast (memcpy) path is only ever reached from `_build_fast` — main-thread/synchronous
		# always (never dispatched to the async worker) — so the LIVE column is always the correct source here.
		gp = _blend_uncovered(_sunk_positions(_bpos_cache[fid], fid), fid, _player_col_abs, _unsink_have_col)
	elif CubeSphere.FP_FARRING_ACTIVE_NOBLACK and fid == _noblack_unsink_fid:
		gp = _bpos_cache[fid]
	else:
		gp = _sunk_positions(_bpos_cache[fid], fid)
	var gc: PackedColorArray = _bcol_cache[fid]
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): the dense backstop grid carries the SAME facet-param UVs (denser cells,
	# same [0,1]² span). Only under FP_FACET_TEX (the caller passes real uv/uv2 arrays); off ⇒ they stay empty.
	var tex := _tex_on()
	var t_a := 0; var t_b := 0; var t_k := 1
	var fuv2 := Vector2.ZERO; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		fuv2 = Vector2(float(d[0]), _uv2_y(fid))
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k); inv_c = 1.0 / float(cells)
	# U2: cull confirmed-covered cells on the fast (memcpy) backstop path too — not appended at all (byte-identical off).
	var cull_dense := _cull_on()
	for gj in range(cells):
		for gi in range(cells):
			if cull_dense and is_cell_culled(fid, gj * cells + gi):
				continue
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			pos.push_back(gp[i0]); pos.push_back(gp[i2]); pos.push_back(gp[i1])
			pos.push_back(gp[i1]); pos.push_back(gp[i2]); pos.push_back(gp[i3])
			col.push_back(gc[i0]); col.push_back(gc[i2]); col.push_back(gc[i1])
			col.push_back(gc[i1]); col.push_back(gc[i2]); col.push_back(gc[i3])
			if tex:
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				uv.push_back(Vector2(u0, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v0))
				uv.push_back(Vector2(u1, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v1))
				for _i in range(6):
					uv2.push_back(fuv2)

## COSMOS far-ring full coverage (§2/§4): emit facet `fid`'s tri soup into `st`. A backstop facet (under FULL_COVER)
## emits its DENSE cache with the BACKSTOP_SINK radial push applied per vertex (pre-computed once here via _sunk_positions
## so a shared grid vertex is not re-normalized per triangle); every other facet emits the shipped CELLS grid verbatim.
## Pure CPU + const reads only — safe on the async worker thread (no scene-tree / RenderingServer access). `sunk` is
## decided by the CALLER (live `_is_backstop` on the main-thread sync path; the frozen `_async_backstop` snapshot on the
## worker) so this function never reads the mutable `_excluded` off-thread.
## FP_BLOCKY_FARRING: emit facet `fid`'s cached grid as flat-topped BLOCKS instead of the smooth welded surface. Per
## grid cell: a FLAT top at MIN(the 4 corner radii) + a vertical wall on each internal edge (closing the height step —
## watertight) + a facet-edge skirt. `pos` already carries the env sink, so the block top (a min of the corners) sits
## ≤ the smooth bilinear surface everywhere ⇒ no-protrusion holds a fortiori (G-BLK-RING). The far-ring material is
## cull_disabled, so wall winding is free.
## COSMOS TEXTURED-LOD T1 (§1.2): under FP_BLOCKY_TEX (caller passes tex=true + the facet `fid`) each top quad carries the
## SAME node-param UVs the smooth _emit_cached path emits — UV = ((a+node_s)/K,(b+node_t)/K), UV2 = (face, slot) — and the
## walls/skirts INHERIT their top-edge nodes' UVs (a vertical smear of the block's own texel stripe). UVs never move a
## vertex (no-protrusion unchanged, G-BT-NOPROT). Off (tex=false, the default / the shipped blocky call) ⇒ NO set_uv/set_uv2
## is issued and the emit is byte-identical to shipped (G-BT-OFF). Returns the triangle count. Reads only the passed arrays
## (+ fid decode, a pure function) → thread-safe on the worker, same as _emit_cached.
func _emit_blocky(st: SurfaceTool, pos: PackedVector3Array, col: PackedColorArray, cells: int, stride: int,
		fid: int = -1, tex: bool = false) -> int:
	var ncell := cells * cells
	var top_r := PackedFloat32Array(); top_r.resize(ncell)
	var dirs := PackedVector3Array(); dirs.resize(stride * stride)
	for i in range(stride * stride):
		var p: Vector3 = pos[i]
		var l := p.length()
		dirs[i] = (p / l) if l > 1.0 else Vector3.UP
	for gj in range(cells):
		for gi in range(cells):
			var i0c := gj * stride + gi
			top_r[gj * cells + gi] = minf(minf(pos[i0c].length(), pos[i0c + 1].length()),
				minf(pos[i0c + stride].length(), pos[i0c + stride + 1].length()))
	# COSMOS TEXTURED-LOD T1 (§1.2): decode the facet's tex params ONCE (identical to _emit_cached). node UV for grid node
	# (ni,nj) = ((a + ni/cells)/K, (b + nj/cells)/K) — the SAME pure function of loop indices the smooth path uses.
	var fuv2 := Vector2.ZERO; var t_a := 0; var t_b := 0; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		fuv2 = Vector2(float(d[0]), _uv2_y(fid))
		t_a = d[1]; t_b = d[2]
		inv_k = 1.0 / float(d[3]); inv_c = 1.0 / float(cells)
	# skirt = one coarse block's radial pitch (the block's own height scale) — facet edges never see through.
	var skirt := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(cells)
	# U2: this facet's cells are cullable only when it is a dense (BACKSTOP_CELLS) backstop AND the cull is active. top_r
	# above is still computed for EVERY cell so an emitted cell adjacent to a culled one keeps its correct flank wall.
	var cull_dense := cells == CubeSphere.BACKSTOP_CELLS and fid >= 0 and _cull_on()
	var n := 0
	for gj in range(cells):
		for gi in range(cells):
			if cull_dense and is_cell_culled(fid, gj * cells + gi):
				continue                    # confirmed covered by near voxels — not emitted at all (no draw, no poke-through)
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			var r: float = top_r[gj * cells + gi]
			var c: Color = col[i0]
			var t0 := dirs[i0] * r; var t1 := dirs[i1] * r; var t2 := dirs[i2] * r; var t3 := dirs[i3] * r
			# node-param UVs of this cell's 4 corners (only computed under tex; off ⇒ Vector2.ZERO, never emitted).
			var uv0 := Vector2.ZERO; var uv1 := Vector2.ZERO; var uv2 := Vector2.ZERO; var uv3 := Vector2.ZERO
			if tex:
				var uu0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var uu1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var vv0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var vv1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				uv0 = Vector2(uu0, vv0); uv1 = Vector2(uu1, vv0)   # i0=(gi,gj)  i1=(gi+1,gj)
				uv2 = Vector2(uu0, vv1); uv3 = Vector2(uu1, vv1)   # i2=(gi,gj+1) i3=(gi+1,gj+1)
			# FLAT top (2 tris) — all four corners at the same (min) radius. UVs = each corner's node param.
			if tex:
				st.set_uv(uv0); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t0)
				st.set_uv(uv2); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t2)
				st.set_uv(uv1); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t1)
				st.set_uv(uv1); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t1)
				st.set_uv(uv2); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t2)
				st.set_uv(uv3); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(t3)
			else:
				st.set_color(c); st.add_vertex(t0)
				st.set_color(c); st.add_vertex(t2)
				st.set_color(c); st.add_vertex(t1)
				st.set_color(c); st.add_vertex(t1)
				st.set_color(c); st.add_vertex(t2)
				st.set_color(c); st.add_vertex(t3)
			n += 2
			# +gi internal edge (shared corners i1,i3) — ONE wall per edge, max→min; boundary edge → skirt.
			if gi + 1 < cells:
				var rn: float = top_r[gj * cells + gi + 1]
				if absf(r - rn) > 0.01:
					n += _emit_wall(st, dirs[i1], dirs[i3], r, rn, c if r >= rn else col[i0 + 1], tex, uv1, uv3, fuv2)
			else:
				n += _emit_wall(st, dirs[i1], dirs[i3], r, r - skirt, c, tex, uv1, uv3, fuv2)
			# +gj internal edge (shared corners i2,i3).
			if gj + 1 < cells:
				var rd: float = top_r[(gj + 1) * cells + gi]
				if absf(r - rd) > 0.01:
					n += _emit_wall(st, dirs[i2], dirs[i3], r, rd, c if r >= rd else col[i0 + stride], tex, uv2, uv3, fuv2)
			else:
				n += _emit_wall(st, dirs[i2], dirs[i3], r, r - skirt, c, tex, uv2, uv3, fuv2)
			# -gi / -gj FACET-boundary skirts (first row/col only) — the outer silhouette against the tier beneath.
			if gi == 0:
				n += _emit_wall(st, dirs[i0], dirs[i2], r, r - skirt, c, tex, uv0, uv2, fuv2)
			if gj == 0:
				n += _emit_wall(st, dirs[i0], dirs[i1], r, r - skirt, c, tex, uv0, uv1, fuv2)
	return n

## FP_BLOCKY_FARRING: a vertical wall quad between two edge directions from top radius to bottom (2 tris). Material is
## cull_disabled so winding is free; emits the higher-block's colour. Caller guarantees a real step (or a skirt).
## COSMOS TEXTURED-LOD T1 (§1.2): under `tex`, both the top AND bottom vert of each side inherit that side's top-edge node
## UV (`uva`/`uvb`) — a vertical smear of the top's texel stripe down the wall; UV2 is the facet-constant `fuv2`. Off ⇒ no
## set_uv/set_uv2 → byte-identical to the shipped wall.
func _emit_wall(st: SurfaceTool, da: Vector3, db: Vector3, r0: float, r1: float, c: Color,
		tex: bool = false, uva: Vector2 = Vector2.ZERO, uvb: Vector2 = Vector2.ZERO, fuv2: Vector2 = Vector2.ZERO) -> int:
	var hi := maxf(r0, r1); var lo := minf(r0, r1)
	var a_hi := da * hi; var b_hi := db * hi; var a_lo := da * lo; var b_lo := db * lo
	if tex:
		st.set_uv(uva); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(a_hi)
		st.set_uv(uva); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(a_lo)
		st.set_uv(uvb); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(b_hi)
		st.set_uv(uvb); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(b_hi)
		st.set_uv(uva); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(a_lo)
		st.set_uv(uvb); st.set_uv2(fuv2); st.set_color(c); st.add_vertex(b_lo)
	else:
		st.set_color(c); st.add_vertex(a_hi)
		st.set_color(c); st.add_vertex(a_lo)
		st.set_color(c); st.add_vertex(b_hi)
		st.set_color(c); st.add_vertex(b_hi)
		st.set_color(c); st.add_vertex(a_lo)
		st.set_color(c); st.add_vertex(b_lo)
	return 2

## `from_worker` (REVISION 2 LAW R-D): true when called from `_async_build_worker` (off the main thread). The R-D
## reduced interim sink reads `_smooth`/`_excluded`/`_active_fid` — MAIN-THREAD-OWNED state (`_smooth.step()` /
## `set_pool_excluded` mutate it while an async build runs concurrently, exactly the hazard `_async_backstop`'s
## frozen-snapshot discipline exists to avoid elsewhere in this file) — so it is evaluated ONLY on the synchronous
## emit path; the async worker keeps the plain full sink unconditionally (byte-identical to pre-R-D there). R-D's
## target — the near-field rim — is a surface/near-voxel concern the async whole-planet path doesn't serve anyway
## (`_shell_orbit()` is true exactly when there is no near voxel field to rim against).
func _emit_cached(st: SurfaceTool, fid: int, sunk: bool, from_worker: bool = false,
		uncovered_true_on := CubeSphere.FP_FARRING_UNCOVERED_TRUE) -> int:
	var pos: PackedVector3Array
	var col: PackedColorArray
	var cells := CELLS
	if sunk:
		# COSMOS FAR-CRUISE NEVER-BLACK: the sub-camera facet where the near field is genuinely absent emits UN-SUNK — at
		# the TRUE radial surface, so it reads as a seamless coarse backstop (never a sunk well). No near voxels exist here
		# to hide behind, so there is nothing to z-fight. Off / covered ⇒ the shipped sink below (byte-identical).
		# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1 (FP_FARRING_UNCOVERED_TRUE): this whole-facet pick is SUPERSEDED by
		# the per-vertex analytic law below when the new flag is on — skip it here so `_noblack_guarantee`'s OTHER
		# jobs (immediate chord-cache build, re-emit arming) keep running verbatim while the actual position choice
		# comes from `_blend_uncovered`.
		if CubeSphere.FP_FARRING_ACTIVE_NOBLACK and fid == _noblack_unsink_fid and not uncovered_true_on:
			pos = _bpos_cache[fid]
		# FP_ENV_FLOORED_ASYNC: a dense CHORD fallback (not yet enveloped) uses the FULL sink so it stays ≤ the near
		# surface; an enveloped dense cache uses the ε sink (the envelope already carries the lower bound). Off ⇒ the
		# shipped backstop_sink() everywhere (byte-identical; _benv_done is empty).
		elif CubeSphere.FP_ENV_FLOORED_ASYNC and not _benv_done.has(fid):
			pos = _sunk_positions_amt(_bpos_cache[fid], TierPlace.backstop_sink_chord())
		elif from_worker:
			pos = _sunk_positions(_bpos_cache[fid])   # async worker — plain sink, never touches main-thread-owned R-D state
		else:
			pos = _sunk_positions(_bpos_cache[fid], fid)   # REVISION 2 LAW R-D: fid-aware interim ε-sink (rim-eligible only)
		# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1: blend the per-vertex analytic un-sink over whichever covered law
		# just picked `pos` above — an uncovered vertex (outside the streamed near ellipsoid) takes the TRUE chord
		# height; a covered vertex keeps `pos` byte-identically. `from_worker` selects the FROZEN column (the worker
		# never reads the live, main-thread-mutated one — the `_async_backstop` freeze contract). Off ⇒ never runs.
		if uncovered_true_on:
			var pcol: Vector3 = _async_unsink_col if from_worker else _player_col_abs
			var have_pcol: bool = _async_unsink_have_col if from_worker else _unsink_have_col
			pos = _blend_uncovered(pos, fid, pcol, have_pcol)
		col = _bcol_cache[fid]
		cells = CubeSphere.BACKSTOP_CELLS
	elif _is_limb_dense(fid):
		# COSMOS PLANET-VIEW §3 (B): a silhouette-ring facet emits its DENSE (LIMB_DENSE_CELLS) un-sunk grid so the limb
		# reads round. ε-sunk under env_all exactly like the coarse path below, so it welds to its CELLS=4 neighbours.
		_ensure_limb_cached(fid)
		pos = _sunk_positions(_limb_pos_cache[fid]) if TierPlace.env_all_on() else _limb_pos_cache[fid]
		col = _limb_col_cache[fid]
		cells = LIMB_DENSE_CELLS
	else:
		# NO-PROTRUSION §0.3: under FP_ENV_ALL the coarse HORIZON cache is an envelope lower bound too — apply the
		# SAME ε sink the backstop gets so the retained emit-time sink covers the between-fine-sample residual (R-A).
		# Off ⇒ the shipped raw _pos_cache emit verbatim (byte-identical).
		pos = _sunk_positions(_pos_cache[fid]) if TierPlace.env_all_on() else _pos_cache[fid]
		col = _col_cache[fid]
	var stride := cells + 1
	var n := 0
	# FP_BLOCKY_FARRING: emit flat-topped blocks instead of the smooth welded grid (same cached pos/col, so no-protrusion
	# holds — the block top is the corner MIN ≤ the smooth surface). Off ⇒ the shipped smooth emit below (byte-identical).
	# COSMOS TEXTURED-LOD T1 (§1.2): under FP_BLOCKY_TEX (∧ FP_FACET_TEX ∧ FP_SHELL_ABSOLUTE, i.e. _tex_on()) the blocky
	# emit ALSO carries the satellite-page node-param UVs so the mega-blocks are textured, not flat-coloured. Off ⇒ tex is
	# false ⇒ NO UV arrays (byte-identical to shipped blocky). _tex_on() gates FP_FACET_TEX ∧ FP_SHELL_ABSOLUTE.
	if CubeSphere.FP_BLOCKY_FARRING:
		return _emit_blocky(st, pos, col, cells, stride, fid, CubeSphere.FP_BLOCKY_TEX and _tex_on())
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): decode the facet's texture params ONCE. With the flag off `tex` is false
	# and the emit runs the shipped set_color/add_vertex sequence VERBATIM (byte-identical, zero overhead).
	var tex := _tex_on()
	var t_a := 0
	var t_b := 0
	var t_k := 1
	var uv2 := Vector2.ZERO
	var inv_k := 0.0
	var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		uv2 = Vector2(float(d[0]), _uv2_y(fid))   # (face, close-up slot -1..243, OR the stable fid under Q2/FP_SLOT_INDIRECT)
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k)
		inv_c = 1.0 / float(cells)
	# U2: cull confirmed-covered cells on the dense (BACKSTOP_CELLS) smooth path — not emitted at all (byte-identical off).
	var cull_dense := cells == CubeSphere.BACKSTOP_CELLS and _cull_on()
	for gj in range(cells):
		for gi in range(cells):
			if cull_dense and is_cell_culled(fid, gj * cells + gi):
				continue
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			if tex:
				# UV = ((a + node_s)/K, (b + node_t)/K); node params: i0=(gi,gj) i1=(gi+1,gj) i2=(gi,gj+1) i3=(gi+1,gj+1)
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				var uv0 := Vector2(u0, v0); var uv1 := Vector2(u1, v0)
				var uv2c := Vector2(u0, v1); var uv3 := Vector2(u1, v1)
				st.set_uv(uv0); st.set_uv2(uv2); st.set_color(col[i0]); st.add_vertex(pos[i0])
				st.set_uv(uv2c); st.set_uv2(uv2); st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_uv(uv1); st.set_uv2(uv2); st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_uv(uv1); st.set_uv2(uv2); st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_uv(uv2c); st.set_uv2(uv2); st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_uv(uv3); st.set_uv2(uv2); st.set_color(col[i3]); st.add_vertex(pos[i3])
			else:
				st.set_color(col[i0]); st.add_vertex(pos[i0])
				st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_color(col[i3]); st.add_vertex(pos[i3])
			n += 2
	return n

## COSMOS-PERF L1: derive facet `fid`'s pre-triangulated pos/col soup from its grid caches, ONCE (cached forever). Expands
## the (CELLS+1)² vertex grid into the SAME 32-tri soup _emit_cached emits (same two tris per cell, same winding, same
## per-vertex colors) so a fast rebuild is a straight append_array of these arrays. Normals are computed later, globally,
## by _build_fast's create_from + generate_normals (they depend on the whole visible set via cross-facet seam smoothing).
func _ensure_tri_cached(fid: int) -> void:
	if _tri_pos_cache.has(fid):
		return
	_ensure_cached(fid)
	# NO-PROTRUSION §0.3: the FAST (memcpy) assembler pre-triangulates the coarse cache; under FP_ENV_ALL bake the
	# same ε sink into that source so a fast rebuild draws the coarse envelope SUNK exactly like the SurfaceTool emit
	# path (_emit_cached). Off ⇒ the shipped raw _pos_cache (byte-identical). The raw _pos_cache itself is untouched
	# (horizon_positions / the weld gate still read the un-sunk envelope).
	var pos: PackedVector3Array = _sunk_positions(_pos_cache[fid]) if TierPlace.env_all_on() else _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	var tp := PackedVector3Array()
	var tc := PackedColorArray()
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): build the parallel tri-order UV/UV2 arrays ONLY under FP_FACET_TEX
	# (off ⇒ these stay empty and _build_fast never reads them → byte-identical). Same push order as pos/col.
	var tex := _tex_on()
	var tu := PackedVector2Array()
	var tu2 := PackedVector2Array()
	var t_a := 0; var t_b := 0; var t_k := 1
	var uv2 := Vector2.ZERO; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): this cache is built ONCE per fid,
		# ever (the `_tri_pos_cache.has(fid): return` guard above), so baking the STABLE fid here (instead of the
		# volatile -1/slot) is permanently correct — no per-rebuild override is needed downstream (`_build_fast`
		# skips its close-up override entirely under this flag, see below). Off ⇒ the shipped -1.0 (byte-identical).
		uv2 = Vector2(float(d[0]), float(fid) if CubeSphere.FP_SLOT_INDIRECT else -1.0)
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k); inv_c = 1.0 / float(CELLS)
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			tp.push_back(pos[i0]); tp.push_back(pos[i2]); tp.push_back(pos[i1])
			tp.push_back(pos[i1]); tp.push_back(pos[i2]); tp.push_back(pos[i3])
			tc.push_back(col[i0]); tc.push_back(col[i2]); tc.push_back(col[i1])
			tc.push_back(col[i1]); tc.push_back(col[i2]); tc.push_back(col[i3])
			if tex:
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				var uv0 := Vector2(u0, v0); var uv1 := Vector2(u1, v0)
				var uv2c := Vector2(u0, v1); var uv3 := Vector2(u1, v1)
				tu.push_back(uv0); tu.push_back(uv2c); tu.push_back(uv1)
				tu.push_back(uv1); tu.push_back(uv2c); tu.push_back(uv3)
				for _i in range(6):
					tu2.push_back(uv2)
	_tri_pos_cache[fid] = tp
	_tri_col_cache[fid] = tc
	if tex:
		_tri_uv_cache[fid] = tu
		_tri_uv2_cache[fid] = tu2

func _centre_dir(fid: int) -> Array:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var cd := _facet_centre_dir(fid)
	_centre_cache[fid] = cd
	return cd

func _facet_centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

## COSMOS LOD-TEXTURE Phase 1 (§1.3): decode `fid` → [face, a, b, k] in its body's local (face,a,b) indexing
## (Earth ⇒ base 0, k=K). The base-map layer is `face`; UV = ((a+s)/k, (b+t)/k). Mirrors FacetTexBaker._decode
## so the emitted UVs land exactly on the baked facet rect.
## COSMOS LOD-TEXTURE Phase 1 (§1.3 / LOW #3): UV/UV2 emission requires BOTH FP_FACET_TEX and FP_SHELL_ABSOLUTE.
## The textured sampler lives ONLY in the (unshaded) _SHELL_ABS_SHADER; under a LIT StandardMaterial the extra
## per-vertex UV/UV2 would split shared-corner verts in generate_normals (faint cube-edge creases) AND never be
## sampled. Gating on both keeps FP_FACET_TEX-alone byte-identical to shipped (no UV arrays, no creases).
func _tex_on() -> bool:
	return CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE

## COSMOS LOD-TEXTURE Phase 4: the close-up tier is live (needs the base textured ring + its own flag). Off ⇒ every
## close-up path (slot injection, closeup sampler, cu_facet uniform) is inert ⇒ the mesh + material are Phase-1-identical.
func _cu_on() -> bool:
	return CubeSphere.FP_FACET_TEX_CLOSEUP and _tex_on()

## COSMOS TEXTURED-LOD U1: the band tier is live (needs the base textured ring + block detail + its own flag). Off ⇒
## every band path (64+ slot, band_map sampler, band_facet/band_n uniforms) is inert ⇒ mesh + material unchanged.
func _bm_on() -> bool:
	return CubeSphere.FP_BAND_BLOCK_MAP and (CubeSphere.FP_BLOCK_DETAIL or CubeSphere.FP_SKIN_FLATCOLOR) and _tex_on()

## The slot for `fid` from the FROZEN build snapshot (worker-safe), fed to UV2.y at emit. A BAND facet wins with 64+layer
## (the shader's real-block path); else the close-up layer (0..63); else −1 (base-map / tiled fallback). Empty snapshots
## (both tiers off / not driven) ⇒ −1 everywhere ⇒ byte-identical to Phase 1.
func _slot_of(fid: int) -> float:
	if _band_slot_snapshot.has(fid):
		return float(64 + int(_band_slot_snapshot[fid]))
	return float(_slot_snapshot.get(fid, -1))

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT, LAW S): the value UV2.y actually carries at
## emit time. On ⇒ the STABLE fid (geometry never needs to change when a slot moves — the shader resolves the live
## slot itself via `_push_slot_indirect`'s lookup texture). Off ⇒ the shipped `_slot_of` bake (byte-identical). `on`
## is a param (mirrors `build_tile`'s `normal_lit`/`_apply_smooth_normal_lit`'s `on` pattern) so a gate can force it
## without flipping the compile-time const.
func _uv2_y(fid: int, on := CubeSphere.FP_SLOT_INDIRECT) -> float:
	return float(fid) if on else _slot_of(fid)

## Q2: the LIVE (non-frozen) combined band/close-up slot for `fid` — the exact `_slot_of` encoding (band 64+layer
## wins, else close-up 0..63, else −1) but read from the LIVE `_band_slots`/`_closeup_slots` maps instead of the
## frozen worker-safe snapshots. Safe: `_push_slot_indirect` runs synchronously on the main thread the instant a
## slot map changes (no async build ever reads these dicts), so there is no race to guard against here.
func _live_slot_of(fid: int) -> float:
	if _band_slots.has(fid):
		return float(64 + int(_band_slots[fid]))
	return float(_closeup_slots.get(fid, -1))

## Q2: the lookup texture's (width, height) — `_SLOT_TEX_W` wide, tall enough to cover the home body's whole fid
## space (`FacetAtlas.facet_count()`, 3456 at K=24) with no wasted row. Recomputed cheaply each call (two int ops);
## not cached, since `facet_count()` itself is O(1) and this never runs per-frame (only on an actual slot-map push).
func _slot_indirect_dims() -> Vector2i:
	var n := FacetAtlas.facet_count()
	return Vector2i(SLOT_TEX_W, (n + SLOT_TEX_W - 1) / SLOT_TEX_W)

## Q2: rebuild the fid→slot lookup texture from the LIVE slot maps — the ONLY thing a slot-map change touches under
## the flag (no mesh re-emit, no `_shell_gen` bump). One `Image.set_pixel` scan over the home body's fid space
## (≤3456 texels, dictionary reads only — no `profile_at_dir`/vertex work) + one `ImageTexture.update()` (a single
## small GPU upload, ~55 KB at K=24 RGBAF) — dramatically cheaper than the full front tri-soup re-emit it replaces.
## `on` is a param (mirrors the codebase's gate-forcing convention) so a headless gate can drive it without
## flipping the compile-time const; real callers always get the const's value. No-op (and no allocation) off.
func _push_slot_indirect(on := CubeSphere.FP_SLOT_INDIRECT) -> void:
	if not on or _mi == null:
		return
	var dims := _slot_indirect_dims()
	var w := dims.x
	var h := dims.y
	if _slot_img == null:
		_slot_img = Image.create(w, h, false, Image.FORMAT_RGBAF)
	var n := FacetAtlas.facet_count()
	for fid in range(n):
		_slot_img.set_pixel(fid % w, int(fid / w), Color(_live_slot_of(fid), 0.0, 0.0, 0.0))
	if _slot_tex == null:
		_slot_tex = ImageTexture.create_from_image(_slot_img)
	else:
		_slot_tex.update(_slot_img)
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("slot_map", _slot_tex)
		(mat as ShaderMaterial).set_shader_parameter("slot_map_w", float(w))

## Q2: react to a close-up/band slot-map change — the ONE decision `set_closeup_slots`/`set_band_slots` used to make
## unconditionally (`_pending = true`, a full front re-emit). `on` mirrors the flag; extracted into its own function
## (rather than inlined at both call sites) so a headless gate can drive EXACTLY this branch directly — bypassing
## the unrelated `_cu_on()`/`_bm_on()` outer guards those setters carry (a pre-existing, separately-gated concern).
func _on_slot_map_changed(on := CubeSphere.FP_SLOT_INDIRECT) -> void:
	if on:
		_push_slot_indirect(true)   # LAW S: update the lookup texture ONLY — no re-emit, no _shell_gen bump
	else:
		_pending = true             # shipped: re-emit so UV2.y carries the new slots (rides the existing deferred pipeline)

## COSMOS LOD-TEXTURE Phase 4 / U1: refresh the frozen slot snapshots the mesh emit reads. MAIN thread only (both build
## entries call it before any worker dispatch), so the async worker's _emit_cached reads maps stable for its run.
func _refresh_slot_snapshot() -> void:
	if _cu_on():
		_slot_snapshot = _closeup_slots.duplicate()
	elif not _slot_snapshot.is_empty():
		_slot_snapshot = {}
	if _bm_on():
		_band_slot_snapshot = _band_slots.duplicate()
	elif not _band_slot_snapshot.is_empty():
		_band_slot_snapshot = {}

func _tex_decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## COSMOS FS1 (§4.1): the unit sphere direction at grid node (s,t) from the SHARED cube-sphere corner dirs `cd`
## (12 f64). The bilerp + normalize stay f64; only the final Vector3 is f32 — so two facets sharing a grid edge
## (identical corner dirs, identical s,t) cast to the SAME f32 direction ⇒ their shared-edge vertices weld.
static func _weld_unit(cd: PackedFloat64Array, s: float, t: float) -> Vector3:
	var ux := _bilerp(cd[0], cd[3], cd[6], cd[9], s, t)
	var uy := _bilerp(cd[1], cd[4], cd[7], cd[10], s, t)
	var uz := _bilerp(cd[2], cd[5], cd[8], cd[11], s, t)
	var ln := sqrt(ux * ux + uy * uy + uz * uz)
	return Vector3(ux / ln, uy / ln, uz / ln)

## COSMOS FS1 (§4.1 / One-Surface Law): the ABSOLUTE radial world point of unit direction `d` at surface height
## `g` — d·(R + relief). The SAME altitude law the datum-shifted near field (FS2) and skin use, so near↔far agree.
static func _weld_place(d: Vector3, g: int) -> Vector3:
	var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
	return d * (FacetAtlas.R_BLOCKS + relief)

## COSMOS FS1 (§4.1): emit grid node (s,t)'s welded radial position + far-palette colour into pos/col.
func _weld_node(cd: PackedFloat64Array, s: float, t: float, pos: PackedVector3Array, col: PackedColorArray) -> void:
	var d := _weld_unit(cd, s, t)
	var prof := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
	var g := int(prof.x)
	pos.append(_weld_place(d, g))
	col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))

## COSMOS FS1 (§4.2): the COARSE-OWNS-EDGE T-junction rule. A dense facet (cells > CELLS) snaps each outer-ring
## INTERIOR vertex onto the CELLS=4 coarse chord (a straight-line interp of the ring's own coarse-index vertices),
## so its shared edge is colinear with — and welds crack-free to — a horizon 4-edge (and to another dense facet
## that snapped the same way). No-op for a horizon facet (cells == CELLS ⇒ cstride 1). Corners are left exact.
static func _weld_snap_edges(pos: PackedVector3Array, cells: int) -> void:
	var cstride := cells / CELLS
	if cstride <= 1:
		return
	var stride := cells + 1
	for i in range(1, cells):
		var c0 := (i / cstride) * cstride                # lower coarse index on the edge
		var c1 := mini(c0 + cstride, cells)              # upper coarse index
		var lo := float(i - c0) / float(cstride)
		pos[i * stride + 0] = pos[c0 * stride + 0].lerp(pos[c1 * stride + 0], lo)            # West (gi=0)
		pos[i * stride + cells] = pos[c0 * stride + cells].lerp(pos[c1 * stride + cells], lo)  # East (gi=cells)
		pos[0 * stride + i] = pos[0 * stride + c0].lerp(pos[0 * stride + c1], lo)             # South (gj=0)
		pos[cells * stride + i] = pos[cells * stride + c0].lerp(pos[cells * stride + c1], lo)  # North (gj=cells)

# COSMOS-LOD-SKY L3 (SHELL_TERMINATOR_TINT, §6b): the space-side terminator band. A lit vertex-colour spatial
# shader (same render class as the StandardMaterial3D / the P3 bias shader) plus a `sun_dir` uniform: per VERTEX
# μ = normalize(world_pos)·sun_dir and ALBEDO *= mix(1, scatter_tint(μ), band(μ)). The scatter_tint/band GLSL MIRRORS
# CosmosSky.scatter_tint/scatter_band EXACTLY (the gate pins the GDScript twin; this shader render is live-only). The
# ONE VISUAL-RISK stage (P3 shader-failure class on gl_compat) — default-off, screenshot-gated; the StandardMaterial
# fallback below is retained permanently. planet centre = scene origin (fixed frame) so normalize(world) is the surface dir.
const _SHELL_TINT_SHADER := "shader_type spatial;
render_mode cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
varying vec3 v_col;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float mu = dot(normalize(wp), normalize(sun_dir));
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col = COLOR.rgb * tint;
}
void fragment() { ALBEDO = v_col; ROUGHNESS = 1.0; }
"

# COSMOS ATMO-SKY A5 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C2): the absolute self-shaded globe shell v2. UNSHADED
# (immune to the global light/ambient, so the globe's look stops tracking the camera) + per-vertex darkening
# NIGHT_FLOOR + (1−NIGHT_FLOOR)·day(n̂), n̂ = normalize(wp − centre) with centre = (MODEL_MATRIX·0) so it is EXACT
# under scale-about-camera (a uniform scale about the camera cancels in the normalize), × the kept terminator
# band tint. Mirrors CosmosSky.day_factor / scatter_tint / scatter_band EXACTLY (gate G-AS-TERM pins the twins).
# Supersedes _SHELL_TINT_SHADER v1; the StandardMaterial fallback below stays permanent (P3 gl_compat class).
const _SHELL_ABS_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
varying vec3 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	float mu = dot(n, normalize(sun_dir));
	float shade = night_floor + (1.0 - night_floor) * _day(mu);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col = COLOR.rgb * shade * tint;
}
void fragment() { ALBEDO = v_col; }
"

# COSMOS LOD-TEXTURE Phase 1 (§1.3): the TEXTURED variant of _SHELL_ABS_SHADER, compiled ONLY under FP_FACET_TEX.
# Identical day/night shade·tint law (the shipped look), but ALBEDO is a per-fragment cross-fade from the raw
# vertex colour to the baked base-map texture, weighted by camera distance: wt = smoothstep(TEX_D0=600,
# TEX_D1=1800, cam_dist). At d < 600 wt = 0 ⇒ ALBEDO == COLOR.rgb·shade·tint EXACTLY (the shipped shell is
# bit-preserved near); above 1800 the smooth satellite image wins. ONE opaque draw — a fragment albedo blend,
# no transparency, no sorting. base_map is bound each session by set_facet_tex (null until then → black texels,
# irrelevant since wt≈0 near where it would show). Phase 1 has NO close-up branch (closeup_map compiled out).
const _SHELL_ABS_TEX_LIGHT := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
uniform sampler2DArray base_map : source_color, filter_linear_mipmap;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
varying vec3 v_col_raw;
varying vec3 v_st;
varying vec2 v_uv;
varying float v_face;
varying float v_cam;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	float mu = dot(n, normalize(sun_dir));
	float shade = night_floor + (1.0 - night_floor) * _day(mu);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col_raw = COLOR.rgb;
	v_st = vec3(shade) * tint;
	v_uv = UV;
	v_face = UV2.x;
	v_cam = distance(wp, CAMERA_POSITION_WORLD);
}
"
const _SHELL_ABS_TEX_ALBEDO := "void fragment() {
	vec4 tx = texture(base_map, vec3(v_uv, v_face));
	// COVERAGE GATE + UN-PREMULTIPLY (§ live-fix 2): the base map is PREMULTIPLIED alpha, so recover the true
	// (un-darkened) colour by dividing rgb by coverage — near a bake frontier this cancels the mip/bilinear
	// average of an un-baked (rgb=0,a=0) neighbour so there is NO black bleed into the seam. tx.a is the bake
	// coverage: multiply wt by it so an un-baked facet (a≈0) shows the shipped vertex-colour far ring (NEVER
	// black from orbit) and the un-premultiply degenerate case falls back to v_col_raw (doubly safe). A baked
	// facet (a=1) cross-fades to the satellite image on the shipped 600..1800 distance ramp. One opaque draw.
	vec3 col = (tx.a > 0.0001) ? (tx.rgb / tx.a) : v_col_raw;
	float wt = tx.a;   // texture EVERYWHERE at ALL distances (user directive): weight = bake coverage only, no distance gate; mip/LOD handles scaling
	ALBEDO = mix(v_col_raw, col, wt) * v_st;
}
"
# COSMOS TEXTURED-LOD §2V PREP (F3): the shell tex shader string is SPLIT into a LIGHT head (uniforms + the
# sun/shade/tint lighting law + vertex()) and an ALBEDO tail (fragment() — texture sampling + the ALBEDO
# composite). Concatenated they are BYTE-IDENTICAL to the pre-split string (verify_shot_prep G-SP-SHADER-
# IDENTICAL pins it against the frozen golden). V1 (unified lighting) edits ONLY the LIGHT head; V2 (band
# shot) edits ONLY the ALBEDO tail — different string constants, no merge conflict. Nothing else changes:
# every existing reader of _SHELL_ABS_TEX_SHADER keeps working (it is now the derived concatenation).
const _SHELL_ABS_TEX_SHADER := _SHELL_ABS_TEX_LIGHT + _SHELL_ABS_TEX_ALBEDO

# COSMOS LOD-TEXTURE Phase 4 (§1.2 T2t / §1.3): the CLOSE-UP variant — the Phase-1 tex shader PLUS a second
# Texture2DArray sampled per-facet at 128² (8× finer). The slot rides UV2.y (v_slot; −1 ⇒ base-map only). The exact
# facet-local UV is (v_uv·K − (a,b)); (a,b) comes from the `cu_facet` reverse-map uniform keyed by the vertex's own
# slot (NOT an in-shader floor of v_uv, which is edge-ambiguous where fract(integer)=0). wc = smoothstep(CLOSEUP_FAR,
# CLOSEUP_NEAR, cam_dist) sharpens on approach; a missing/uncovered slot degrades to the base map (softening, never a
# hole). Compiled ONLY under FP_FACET_TEX_CLOSEUP; the base branch is byte-identical to _SHELL_ABS_TEX_SHADER so a
# facet with slot −1 renders exactly the Phase-1 result. cu_facet[64] MUST match CubeSphere.CLOSEUP_MAX.
const _SHELL_ABS_TEX_CU_LIGHT := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
uniform sampler2DArray base_map : source_color, filter_linear_mipmap;
uniform sampler2DArray closeup_map : source_color, filter_linear_mipmap;
uniform vec2 cu_facet[64];
uniform float cu_k = 24.0;
uniform float cu_near = 1200.0;
uniform float cu_far = 4000.0;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
varying vec3 v_col_raw;
varying vec3 v_st;
varying vec2 v_uv;
varying float v_face;
varying float v_slot;
varying float v_cam;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	float mu = dot(n, normalize(sun_dir));
	float shade = night_floor + (1.0 - night_floor) * _day(mu);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col_raw = COLOR.rgb;
	v_st = vec3(shade) * tint;
	v_uv = UV;
	v_face = UV2.x;
	v_slot = UV2.y;
	v_cam = distance(wp, CAMERA_POSITION_WORLD);
}
"
const _SHELL_ABS_TEX_CU_ALBEDO := "void fragment() {
	vec4 tx = texture(base_map, vec3(v_uv, v_face));
	vec3 col = (tx.a > 0.0001) ? (tx.rgb / tx.a) : v_col_raw;
	float cov = tx.a;
	if (v_slot >= 0.0) {
		int s = int(v_slot + 0.5);
		vec2 ab = cu_facet[s];
		vec2 local = clamp(vec2(v_uv.x * cu_k - ab.x, v_uv.y * cu_k - ab.y), 0.0, 1.0);
		vec4 cu = texture(closeup_map, vec3(local, v_slot));
		vec3 cucol = (cu.a > 0.0001) ? (cu.rgb / cu.a) : col;   // premultiplied like the base page
		float wc = smoothstep(cu_far, cu_near, v_cam) * cu.a;   // sharpen on approach, coverage-gated
		col = mix(col, cucol, wc);
		cov = max(cov, cu.a);
	}
	float wt = cov;   // texture EVERYWHERE at ALL distances (user directive): weight = bake coverage only, no distance gate
	ALBEDO = mix(v_col_raw, col, wt) * v_st;
}
"
# COSMOS TEXTURED-LOD §2V PREP (F3): the shell tex shader string is SPLIT into a LIGHT head (uniforms + the
# sun/shade/tint lighting law + vertex()) and an ALBEDO tail (fragment() — texture sampling + the ALBEDO
# composite). Concatenated they are BYTE-IDENTICAL to the pre-split string (verify_shot_prep G-SP-SHADER-
# IDENTICAL pins it against the frozen golden). V1 (unified lighting) edits ONLY the LIGHT head; V2 (band
# shot) edits ONLY the ALBEDO tail — different string constants, no merge conflict. Nothing else changes:
# every existing reader of _SHELL_ABS_TEX_CU_SHADER keeps working (it is now the derived concatenation).
const _SHELL_ABS_TEX_CU_SHADER := _SHELL_ABS_TEX_CU_LIGHT + _SHELL_ABS_TEX_CU_ALBEDO

# COSMOS TEXTURED-LOD T1b (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R.1/§2R.3): inject the block-FACE detail sampling into
# the ALREADY-COMPILED shell tex shader string — no new shader_type, no new compiled program (same one shell program per
# session). Two string replacements on the EXISTING code: (1) declare the shared `detail_map` (REPEAT, mip) + the per-
# texel `id_map` (NEAREST) samplers after `base_map`; (2) replace the final ALBEDO line so, when a texel's id > 0, the
# composed colour `col` is modulated by that material's real block face at ONE tile per macro texel (buv = v_uv·384,
# REPEAT). Because each detail layer is mean-normalised (mean 0.5) and `face_col = col·detail·2.0`, the pattern mips back
# to `col` with distance ⇒ far degrades to exactly the colour map (§2R.2). Off FP_BLOCK_DETAIL ⇒ the code is returned
# UNCHANGED (byte-identical shader string, identical program) — the G-BD-OFF identity. Applied to BOTH tex variants
# (base + close-up): the base id/frequency modulates whatever `col` the fragment composed (close-up id twin deferred).
const _DETAIL_UNIFORMS := "uniform sampler2DArray detail_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray id_map : filter_nearest;
const float DETAIL_PAGE = 384.0;
"
const _DETAIL_ALBEDO := "	int _mid = int(texelFetch(id_map, ivec3(clamp(ivec2(v_uv * DETAIL_PAGE), ivec2(0), ivec2(int(DETAIL_PAGE) - 1)), int(v_face + 0.5)), 0).r * 255.0 + 0.5);
	vec3 _face = col * texture(detail_map, vec3(v_uv * DETAIL_PAGE, float(_mid))).rgb * 2.0;
	ALBEDO = mix(v_col_raw, (_mid > 0) ? _face : col, wt) * v_st;
"

# COSMOS TEXTURED-LOD U1 (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2U.1: FP_BAND_BLOCK_MAP): the BAND real-block injection,
# ADDITIVE on top of the FP_BLOCK_DETAIL injection — same string-splice discipline, ZERO new shader_type/compiled
# programs (still exactly ONE per shell string). For a BAND facet (UV2.y ≥ 64 → band slot = UV2.y − 64) the fragment
# reads the per-block material id from `band_map` at the fragment's block coord (buv = facet-local-uv · band_n[slot])
# and composites detail_map[id] at the intra-block UV (fract(buv)) — reconstructing PER PIXEL the analytic real
# top-down composite of the facet's ACTUAL blocks at their ACTUAL positions. A non-band facet (UV2.y < 64) falls
# through to the §2R.1 tiled id_map path unchanged (far-far degrades gracefully). Injected only under FP_BAND_BLOCK_MAP;
# off ⇒ the shader string is EXACTLY the FP_BLOCK_DETAIL result (G-BB-OFF byte-identity). BAND_LAYERS is interpolated
# as a literal so the GLSL array sizes are integer-constant.
const _BAND_UNIFORMS := "uniform sampler2DArray band_map : filter_nearest;
uniform vec2 band_facet[%d];
uniform vec2 band_n[%d];
uniform float band_k = 24.0;
"
const _BAND_ALBEDO := "	int _bs = int(v_bslot + 0.5) - 64;
	if (v_bslot >= 63.5 && _bs < %d) {
		vec2 _ab = band_facet[_bs];
		vec2 _luv = clamp(vec2(v_uv.x * band_k - _ab.x, v_uv.y * band_k - _ab.y), 0.0, 1.0);
		vec2 _N = band_n[_bs];
		vec2 _buv = _luv * _N;
		ivec2 _ib = clamp(ivec2(_buv), ivec2(0), ivec2(_N) - ivec2(1));
		int _bid = int(texelFetch(band_map, ivec3(_ib, _bs), 0).r * 255.0 + 0.5);
		vec3 _bcol = (_bid > 0) ? (col * texture(detail_map, vec3(fract(_buv), float(_bid))).rgb * 2.0) : col;
		ALBEDO = mix(v_col_raw, _bcol, wt) * v_st;
	} else {
		int _mid = int(texelFetch(id_map, ivec3(clamp(ivec2(v_uv * DETAIL_PAGE), ivec2(0), ivec2(int(DETAIL_PAGE) - 1)), int(v_face + 0.5)), 0).r * 255.0 + 0.5);
		vec3 _face = col * texture(detail_map, vec3(v_uv * DETAIL_PAGE, float(_mid))).rgb * 2.0;
		ALBEDO = mix(v_col_raw, (_mid > 0) ? _face : col, wt) * v_st;
	}
"
# COSMOS TEXTURED-LOD §2V V2 (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.1: FP_BAND_SHOT): the SHOT band branch. Identical
# addressing to _BAND_ALBEDO, but the band_map is RG8 {block_id, shade}: read BOTH channels (.rg), decode R→id (the top
# block INCLUDING trees, since surface_shot composited the canopy), and MULTIPLY the sun-independent shade byte (.g) into
# the per-block face so the composite is `col · detail_tile[id] · 2 · shade` = detail_tile[id] × tint × shade — the real
# top-down shot with its baked AO/hillshade/canopy/water depth. The live sun/moon shade·tint (v_st) is applied on top
# UNCHANGED (single-owner rule §2V.6 F4: v_st owns dynamic light, band shade owns static depth — no double-darkening).
# The far-far ELSE tiled path is byte-identical to _BAND_ALBEDO's. Injected only when FP_BAND_SHOT is on (else _BAND_ALBEDO
# verbatim); still ONE string splice ⇒ zero new compiled programs. %d = BAND_LAYERS (same literal as _BAND_ALBEDO).
const _BAND_SHOT_ALBEDO := "	int _bs = int(v_bslot + 0.5) - 64;
	if (v_bslot >= 63.5 && _bs < %d) {
		vec2 _ab = band_facet[_bs];
		vec2 _luv = clamp(vec2(v_uv.x * band_k - _ab.x, v_uv.y * band_k - _ab.y), 0.0, 1.0);
		vec2 _N = band_n[_bs];
		vec2 _buv = _luv * _N;
		ivec2 _ib = clamp(ivec2(_buv), ivec2(0), ivec2(_N) - ivec2(1));
		vec2 _rg = texelFetch(band_map, ivec3(_ib, _bs), 0).rg;
		int _bid = int(_rg.r * 255.0 + 0.5);
		vec3 _bcol = (_bid > 0) ? (col * texture(detail_map, vec3(fract(_buv), float(_bid))).rgb * 2.0 * _rg.g) : col;
		ALBEDO = mix(v_col_raw, _bcol, wt) * v_st;
	} else {
		int _mid = int(texelFetch(id_map, ivec3(clamp(ivec2(v_uv * DETAIL_PAGE), ivec2(0), ivec2(int(DETAIL_PAGE) - 1)), int(v_face + 0.5)), 0).r * 255.0 + 0.5);
		vec3 _face = col * texture(detail_map, vec3(v_uv * DETAIL_PAGE, float(_mid))).rgb * 2.0;
		ALBEDO = mix(v_col_raw, (_mid > 0) ? _face : col, wt) * v_st;
	}
"
static func _apply_block_detail(code: String, band := CubeSphere.FP_BAND_BLOCK_MAP, shot := CubeSphere.FP_BAND_SHOT) -> String:
	if not CubeSphere.FP_BLOCK_DETAIL:
		return code
	code = code.replace(
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n",
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n" + _DETAIL_UNIFORMS)
	code = code.replace(
		"	ALBEDO = mix(v_col_raw, col, wt) * v_st;\n", _DETAIL_ALBEDO)
	# COSMOS TEXTURED-LOD U1: layer the BAND real-block path on top when FP_BAND_BLOCK_MAP is on. Additive: declare the
	# band uniforms after the detail ones, carry UV2.y into a v_bslot varying, and swap the tiled ALBEDO block for the
	# band-branching one (band facet ⇒ real per-block map; else the identical tiled path). Byte-identical to the
	# FP_BLOCK_DETAIL result when the flag is off. `band` is a param (defaults to the flag) so the gate can build both.
	if band:
		var bl := CubeSphere.BAND_LAYERS
		code = code.replace(_DETAIL_UNIFORMS, _DETAIL_UNIFORMS + (_BAND_UNIFORMS % [bl, bl]))
		code = code.replace("varying float v_face;\n", "varying float v_face;\nvarying float v_bslot;\n")
		code = code.replace("	v_face = UV2.x;\n", "	v_face = UV2.x;\n	v_bslot = UV2.y;\n")
		# COSMOS TEXTURED-LOD §2V V2 (FP_BAND_SHOT): the band branch reads RG8 {id, shade} — it multiplies the baked
		# sun-independent shade into the per-block face so ALBEDO = detail_tile[id] × tint × shade (the real shot incl the
		# baked AO/hillshade depth). `shot` is a param (defaults to the flag) so the gate can build both; off ⇒ the U1 L8
		# id-only band branch VERBATIM (byte-identical). Both variants are ONE string splice — zero new compiled programs.
		var band_albedo := _BAND_SHOT_ALBEDO if shot else _BAND_ALBEDO
		code = code.replace(_DETAIL_ALBEDO, band_albedo % bl)
		# When the close-up variant is live, its UV2.y also carries band slots (64+): guard the close-up branch to the
		# 0..63 slot space so a band facet never indexes closeup_map out of range. No-op on the base tex shader.
		code = code.replace("	if (v_slot >= 0.0) {\n", "	if (v_slot >= 0.0 && v_slot < 63.5) {\n")
	return code

# FP_SKIN_FLATCOLOR (Minecraft-style per-block MAP SKIN): render a band-resident texel as a FLAT tile-mean COLOUR
# (far_lut[id-1], the frozen_colors tile-mean palette) instead of the detail_map texture pattern. NO detail_map / id_map
# dependency (drops FP_BLOCK_DETAIL) — a band facet shows per-block colours, a non-band facet falls to the coarse base
# col (sub-pixel far limb). Mirrors the _BAND_ALBEDO addressing exactly; %d = BAND_LAYERS, far_lut sized to the palette.
const _FLAT_UNIFORMS := "uniform sampler2DArray band_map : filter_nearest;
uniform vec2 band_facet[%d];
uniform vec2 band_n[%d];
uniform float band_k = 24.0;
uniform vec3 far_lut[%d];
"
const _FLAT_ALBEDO := "	int _bs = int(v_bslot + 0.5) - 64;
	if (v_bslot >= 63.5 && _bs < %d) {
		vec2 _ab = band_facet[_bs];
		vec2 _luv = clamp(vec2(v_uv.x * band_k - _ab.x, v_uv.y * band_k - _ab.y), 0.0, 1.0);
		vec2 _N = band_n[_bs];
		ivec2 _ib = clamp(ivec2(_luv * _N), ivec2(0), ivec2(_N) - ivec2(1));
		int _bid = int(texelFetch(band_map, ivec3(_ib, _bs), 0).r * 255.0 + 0.5);
		vec3 _bcol = (_bid > 0) ? far_lut[_bid - 1] : col;
		float _w = max(wt, (_bid > 0) ? 1.0 : 0.0);
		ALBEDO = mix(v_col_raw, _bcol, _w) * v_st;
	} else {
		ALBEDO = mix(v_col_raw, col, wt) * v_st;
	}
"
const _FINE_UNIFORM := "uniform sampler2DArray fine_map : filter_nearest;\n"
const _FINE_ELSE := "\t} else {
\t\tvec2 _q = clamp(floor(v_uv * 2.0), 0.0, 1.0);
\t\tint _fl = int(v_face + 0.5) * 4 + int(_q.y) * 2 + int(_q.x);
\t\tivec2 _fi = clamp(ivec2(fract(v_uv * 2.0) * %d.0), ivec2(0), ivec2(%d));
\t\tint _f8 = int(texelFetch(fine_map, ivec3(_fi, _fl), 0).r * 255.0 + 0.5);
\t\tvec3 _fc = (_f8 > 0) ? far_lut[_f8 - 1] : col;
\t\tALBEDO = mix(v_col_raw, _fc, max(wt, (_f8 > 0) ? 1.0 : 0.0)) * v_st;
\t}"
const _FLAT_UNIFORMS_META := "uniform sampler2DArray band_map : filter_nearest;
uniform sampler2D band_meta : filter_nearest;
uniform float band_k = 24.0;
uniform vec3 far_lut[%d];
"
const _FLAT_ALBEDO_META := "	int _bs = int(v_bslot + 0.5) - 64;
	if (v_bslot >= 63.5) {
		vec4 _m = texelFetch(band_meta, ivec2(_bs, 0), 0);
		vec2 _ab = _m.xy;
		vec2 _luv = clamp(vec2(v_uv.x * band_k - _ab.x, v_uv.y * band_k - _ab.y), 0.0, 1.0);
		vec2 _N = _m.zw;
		ivec2 _ib = clamp(ivec2(_luv * _N), ivec2(0), ivec2(_N) - ivec2(1));
		int _bid = int(texelFetch(band_map, ivec3(_ib, _bs), 0).r * 255.0 + 0.5);
		vec3 _bcol = (_bid > 0) ? far_lut[_bid - 1] : col;
		float _w = max(wt, (_bid > 0) ? 1.0 : 0.0);
		ALBEDO = mix(v_col_raw, _bcol, _w) * v_st;
	} else {
		ALBEDO = mix(v_col_raw, col, wt) * v_st;
	}
"
## FP_PLANET_MAP composite with the fine tier as the UNIVERSAL fallback (Fable audit F1 ii/iii). The whole-planet
## fine sample is hoisted ABOVE the band branch, so a band facet whose texel is un-baked (_bid==0, mid-bake) OR whose
## slot was evicted (band_meta sentinel _m.x < -0.5) falls to the FINE tier — which is always resident + baked —
## instead of the pale coarse base. That removes the washed patches the band showed during its slow per-facet bake
## (the centre-quad's remaining cause below the promote reach), while a BAKED band texel still overrides fine (sharp
## 1 blk/texel on close approach). %d = fine sub-page edge (PLANET_MAP_QUAD·TEXELS).
const _FLAT_ALBEDO_META_FINE := "	vec2 _q = clamp(floor(v_uv * 2.0), 0.0, 1.0);
	int _fl = int(v_face + 0.5) * 4 + int(_q.y) * 2 + int(_q.x);
	ivec2 _fi = clamp(ivec2(fract(v_uv * 2.0) * %d.0), ivec2(0), ivec2(%d));
	int _f8 = int(texelFetch(fine_map, ivec3(_fi, _fl), 0).r * 255.0 + 0.5);
	vec3 _fc = (_f8 > 0) ? far_lut[_f8 - 1] : col;
	float _fw = (_f8 > 0) ? 1.0 : 0.0;
	if (v_bslot >= 63.5) {
		int _bs = int(v_bslot + 0.5) - 64;
		vec4 _m = texelFetch(band_meta, ivec2(_bs, 0), 0);
		vec3 _bc; float _bw;
		if (_m.x < -0.5) {
			_bc = _fc; _bw = _fw;
		} else {
			vec2 _ab = _m.xy;
			vec2 _luv = clamp(vec2(v_uv.x * band_k - _ab.x, v_uv.y * band_k - _ab.y), 0.0, 1.0);
			vec2 _N = _m.zw;
			ivec2 _ib = clamp(ivec2(_luv * _N), ivec2(0), ivec2(_N) - ivec2(1));
			int _bid = int(texelFetch(band_map, ivec3(_ib, _bs), 0).r * 255.0 + 0.5);
			_bc = (_bid > 0) ? far_lut[_bid - 1] : _fc;
			_bw = (_bid > 0) ? 1.0 : _fw;
		}
		ALBEDO = mix(v_col_raw, _bc, max(wt, _bw)) * v_st;
	} else {
		ALBEDO = mix(v_col_raw, _fc, max(wt, _fw)) * v_st;
	}
"
static func _apply_flatcolor(code: String) -> String:
	var bl := CubeSphere.BAND_LAYERS
	var nlut := FarPalette.frozen_colors().size()
	var base_decl := "uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n"
	if CubeSphere.FP_BAND_META_TEX:
		# FP_BAND_META_TEX: band reverse-map via a data texture (texelFetch) instead of uniform arrays → no vec-uniform cap.
		var unis := _FLAT_UNIFORMS_META % nlut
		var meta_albedo := _FLAT_ALBEDO_META
		if CubeSphere.FP_PLANET_MAP:
			# FP_PLANET_MAP: always-resident whole-planet fine tier — the UNIVERSAL fallback (band un-baked/evicted → fine,
			# never the pale base; Fable audit F1 ii/iii). Hoisted-fine albedo replaces the whole band+else composite.
			var pg := CubeSphere.PLANET_MAP_QUAD * CubeSphere.PLANET_MAP_TEXELS
			unis = unis + _FINE_UNIFORM
			meta_albedo = _FLAT_ALBEDO_META_FINE % [pg, pg - 1]
		code = code.replace(base_decl, base_decl + unis)
		code = code.replace("varying float v_face;\n", "varying float v_face;\nvarying float v_bslot;\n")
		code = code.replace("	v_face = UV2.x;\n", "	v_face = UV2.x;\n	v_bslot = UV2.y;\n")
		code = code.replace("	ALBEDO = mix(v_col_raw, col, wt) * v_st;\n", meta_albedo)
		code = code.replace("	if (v_slot >= 0.0) {\n", "	if (v_slot >= 0.0 && v_slot < 63.5) {\n")
		return code
	code = code.replace(base_decl, base_decl + (_FLAT_UNIFORMS % [bl, bl, nlut]))
	code = code.replace("varying float v_face;\n", "varying float v_face;\nvarying float v_bslot;\n")
	code = code.replace("	v_face = UV2.x;\n", "	v_face = UV2.x;\n	v_bslot = UV2.y;\n")
	code = code.replace("	ALBEDO = mix(v_col_raw, col, wt) * v_st;\n", _FLAT_ALBEDO % bl)
	code = code.replace("	if (v_slot >= 0.0) {\n", "	if (v_slot >= 0.0 && v_slot < 63.5) {\n")
	return code

# COSMOS TEXTURED-LOD V1 (FP_SHADE_UNIFIED, docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.3): swap the shell LIGHT head's inline
# lighting law for the SHARED VoxiLight.SHADE_GLSL snippet (string-included — pure concatenation, ZERO new shader_type /
# compiled program). Four surgical replacements, all on the LIGHT head ONLY (the ALBEDO tail / texture sampling is
# untouched, so V2 never conflicts): (1) the 3-uniform block → the snippet (which declares sun_dir/night_floor/term_mu +
# moonshine + the helpers + voxi_shade); (2) delete the now-duplicate inline helper fns; (3) delete the inline mu/shade/
# tint compute; (4) emit the shade·tint via voxi_shade(n, sun_dir). Adds the moonshine floor the far shell lacked; the
# TRUE planet-radial normal n = normalize(wp − centre) is ALREADY the shell's normal (centre = MODEL·0), so the far
# texel now matches the near block top exactly. Applies to BOTH tex variants and the non-tex _SHELL_ABS_SHADER (their
# v_st / v_col emit lines differ — both handled). `unified` is a param (defaults to the flag) so the gate builds both.
# Off ⇒ every anchor is left untouched (String.replace of an absent/identity anchor is a no-op) ⇒ code returned VERBATIM.
static func _apply_shade_unified(code: String, unified := CubeSphere.FP_SHADE_UNIFIED) -> String:
	if not unified:
		return code
	# (1) delete the inline helper functions FIRST — before the snippet is inserted — so this only strips the shell's
	# own copy and never the identical block the snippet re-supplies (order matters: SHADE_GLSL contains these lines).
	code = code.replace(
		"float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }\nvec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }\nfloat _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }\nfloat _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }\n",
		"")
	# (2) uniforms → shared snippet (declares sun_dir/night_floor/term_mu/moonshine + helpers + voxi_shade)
	code = code.replace(
		"uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);\nuniform float night_floor = 0.06;\nuniform float term_mu = 0.12;\n",
		VoxiLight.shade_glsl())
	# (3) delete the inline mu/shade/tint compute (voxi_shade now carries it)
	code = code.replace(
		"	float mu = dot(n, normalize(sun_dir));\n	float shade = night_floor + (1.0 - night_floor) * _day(mu);\n	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));\n",
		"")
	# (4) emit shade·tint via the shared law — the tex variants store v_st, the non-tex shell folds it into v_col
	code = code.replace("	v_st = vec3(shade) * tint;\n", "	v_st = voxi_shade(n, sun_dir);\n")
	code = code.replace("	v_col = COLOR.rgb * shade * tint;\n", "	v_col = COLOR.rgb * voxi_shade(n, sun_dir);\n")
	return code

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2 (FP_SMOOTH_NORMAL_LIT): relief LIGHTING for the smooth far tiles. The
# shell (and the biased-tier TierPlace fallback) shade every vertex with the exact planet-RADIAL normal
# n = normalize(wp - centre) — continuous and seam-free, but relief-BLIND (a mountain flank facing away from the Sun
# shades identically to flat ground at the same latitude). The smooth tiles now carry a REAL per-vertex relief normal
# (P0's canon-welded FarDensity.boundary_normal + facet_smooth_tier.gd's interior gradient stencil, already proven
# seam-continuous across facet borders — G-FS-NRM-CONT) — this splice reads THAT normal instead, for smooth-tile
# fragments only, so sunlit slopes brighten and lee slopes darken and the S-tier relief actually reads as mountains.
# DISCRIMINATOR: the shell and the smooth tiles share ONE ShaderMaterial (setup_instance passes the ring's own
# material_override straight through — facet_smooth_tier.gd:302-303 "comes for free"), so there is no per-draw-call
# uniform to branch on; instead FacetSmoothTier.build_tile stamps COLOR.a = 0 on its OWN vertices only under this
# flag (the shell's vertex colour, FarPalette.color_for, is unconditionally alpha=1 — COLOR.a is read NOWHERE else
# in this shader family: every existing reader takes only `.rgb`). ONE string replacement of the shared
# "vec3 n = normalize(wp - centre);" anchor — present, byte-identical, in every FP_SHELL_ABSOLUTE shell variant; no
# new shader_type/compiled program, no new uniform. `on` is a param (defaults to the flag) so the gate builds both
# without toggling CubeSphere. Off, or the anchor absent (SHELL_TERMINATOR_TINT's older `_SHELL_TINT_SHADER`, which
# has no `centre`-relative normal to swap), ⇒ code returned VERBATIM — String.replace of an absent/off anchor is a
# no-op (the F7 golden-string discipline).
static func _apply_smooth_normal_lit(code: String, on := CubeSphere.FP_SMOOTH_NORMAL_LIT) -> String:
	if not on:
		return code
	return code.replace(
		"	vec3 n = normalize(wp - centre);\n",
		"	vec3 n = (COLOR.a < 0.5) ? normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz) : normalize(wp - centre);\n")

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT, LAW S): resolve the band/close-up skin slot
# through a fid-indexed LOOKUP TEXTURE instead of trusting it baked into UV2.y directly. `v_slot` (the CU variant)
# and/or `v_bslot` (band injections, `_apply_block_detail`/`_apply_flatcolor`) are assigned `= UV2.y` at the vertex
# stage EXACTLY as shipped — under this flag the GDScript emit side (`_uv2_y`) feeds UV2.y the STABLE FID instead of
# the volatile slot, so at this point `v_slot`/`v_bslot` (whichever exist in THIS variant) simply CONTAIN the fid.
# One additive texelFetch resolves it to the CURRENT slot, right at the top of fragment() before anything reads it —
# gl_compat-SAFE: `sampler2D` + `texelFetch(..., ivec2, 0)` is the EXACT pattern already shipped for `band_meta`
# (`facet_far_ring.gd` `_push_band_meta`) and `band_map`/`id_map`/`fine_map` (all `filter_nearest` sampler2DArrays) —
# proven to compile/run on WebGL2/ANGLE across several prior stages. No vertex-stage texture fetch is used (some
# gl_compat/ANGLE stacks limit vertex texture image units), and no integer vertex ATTRIBUTE is required (the fid
# rides the SAME float UV2.y attribute the slot always did — only its meaning changes).
# Applied to the FULLY ASSEMBLED shader string (after `_apply_block_detail`/`_apply_flatcolor`/`_apply_shade_unified`/
# `_apply_smooth_normal_lit` have already run) — a single anchor-based splice covers every variant. A variant that
# never declares `v_slot` or `v_bslot` (the plain vertex-colour shell, or the base tex shader with neither close-up
# nor band on) has NOTHING for Q2 to resolve — the anchor is simply absent, so the code returns UNTOUCHED (the F7
# golden-string discipline: String.replace of an absent anchor is a no-op). Off ⇒ code returned VERBATIM always.
# REVISION 4 Stage A (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md R4.1, Q2'): rounded, integer-exact decode. The
# ORIGINAL Q2 decode (`mod(fid, w)`/`floor(fid / w)` on an un-rounded float) has NO defence against the barycentric
# reconstruction dropping a constant-across-the-triangle varying a few ulp under its true integer value (fid≈3455
# reconstructed as 3454.9997 flips BOTH `mod` and the row) — every OTHER decoder already shipped in this family
# rounds first (`int(v_bslot + 0.5)`, ~3698/3722). `fid < 0.0` (the "no slot") guard returns the same −1 sentinel the
# fragment paths already treat as "no slot" everywhere else in this shader family.
const _SLOT_INDIRECT_UNIFORMS := "uniform sampler2D slot_map : filter_nearest;
uniform float slot_map_w = 64.0;
float _slot_indirect(float fid) {
	if (fid < 0.0) { return -1.0; }
	int f = int(fid + 0.5);
	int w = int(slot_map_w + 0.5);
	return texelFetch(slot_map, ivec2(f % w, f / w), 0).r;
}
"
# REVISION 4 Stage A (R4.1, Q2'): resolve in the VERTEX stage, where assigning the varying is legal (the ORIGINAL
# splice injected `v_slot = _slot_indirect(v_slot);` / `v_bslot = _slot_indirect(v_bslot);` at the TOP of
# `fragment()` — but `v_slot`/`v_bslot` are varyings ALREADY ASSIGNED in `vertex()` a few lines above, and Godot's
# shader compiler hard-rejects reassigning a vertex-assigned varying in fragment/light (engine source,
# `servers/rendering/shader_language.cpp` `_validate_varying_assign`) — the WHOLE far-ring shader fails to parse on
# any real renderer and falls back to the engine's default white material; headless gates never caught it because
# the dummy RenderingServer stores `shader_code` without ever parsing it). Fix: splice the VERTEX-stage assignment
# itself — `v_slot = UV2.y;` → `v_slot = _slot_indirect(UV2.y);` (and the `v_bslot` twin(s); `_apply_block_detail`/
# `_apply_flatcolor` inject the identical `\tv_bslot = UV2.y;\n` literal at up to 3 call sites, all already collapsed
# into the SAME string by the time this runs on the fully-assembled code, so ONE replace covers all of them). The
# fragment body is UNTOUCHED — it already decodes with `int(x + 0.5)` (~3698/3722), so a varying now carrying the
# resolved (small-magnitude) slot instead of the raw fid needs no fragment-side change at all.
static func _apply_slot_indirect(code: String, on := CubeSphere.FP_SLOT_INDIRECT) -> String:
	if not on:
		return code
	var has_slot := code.find("varying float v_slot;") >= 0
	var has_bslot := code.find("varying float v_bslot;") >= 0
	if not has_slot and not has_bslot:
		return code   # this variant never reads UV2.y as a slot at all — nothing for Q2 to resolve
	code = code.replace(
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n",
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n" + _SLOT_INDIRECT_UNIFORMS)
	if has_slot:
		code = code.replace("\tv_slot = UV2.y;\n", "\tv_slot = _slot_indirect(UV2.y);\n")
	if has_bslot:
		code = code.replace("\tv_bslot = UV2.y;\n", "\tv_bslot = _slot_indirect(UV2.y);\n")
	return code

# REVISION 4 G-FS-VARY-STAGE: pure string lint, no shader compiler involved — extract the `vertex()` and
# `fragment()`/`light()` function bodies from an assembled shader string (brace-matched) and report every DECLARED
# `varying` that is ASSIGNED (an `ident =` NOT `ident ==`) in the vertex body AND ALSO in the fragment/light body.
# That reassignment is exactly the illegal pattern Godot's shader compiler rejects (a vertex-assigned varying may
# not be reassigned in fragment/light) — this is the headless PROXY for a real GLSL parse (the dummy RenderingServer
# never parses `shader_set_code`, so nothing shorter than an actual GPU context can confirm compilation; this lints
# the RULE the parser enforces). Returns the OFFENDING varying names; empty ⇒ no cross-stage reassignment found.
static func lint_varying_stage_conflicts(code: String) -> PackedStringArray:
	var violations := PackedStringArray()
	var varying_re := RegEx.new()
	varying_re.compile("varying\\s+\\w+\\s+(\\w+)\\s*;")
	var names: Dictionary = {}
	for m in varying_re.search_all(code):
		names[m.get_string(1)] = true
	var vert_body := _extract_fn_body(code, "vertex")
	var non_vert_body := _extract_fn_body(code, "fragment") + "\n" + _extract_fn_body(code, "light")
	for vname in names.keys():
		var assign_re := RegEx.new()
		assign_re.compile("\\b" + String(vname) + "\\s*=(?!=)")
		if assign_re.search(vert_body) != null and assign_re.search(non_vert_body) != null:
			violations.append(vname)
	return violations

## Brace-matched extraction of `void <fn_name>() { ... }`'s body from a shader source string. Empty string if the
## function isn't declared at all (a variant with no `light()`, say) — never an error, just nothing to scan.
static func _extract_fn_body(code: String, fn_name: String) -> String:
	var idx := code.find("void " + fn_name + "()")
	if idx < 0:
		return ""
	var brace_start := code.find("{", idx)
	if brace_start < 0:
		return ""
	var depth := 0
	var i := brace_start
	while i < code.length():
		var c := code[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return code.substr(brace_start + 1, i - brace_start - 1)
		i += 1
	return code.substr(brace_start + 1)

# REVISION 4 G-SLOT-DECODE: pure-GDScript mirrors of the GLSL `_slot_indirect` decode — the headless proxy for a
# fragment-side `texelFetch` address (no GPU context runs headless). `slot_indirect_decode` mirrors the FIXED,
# rounded decode (`int(fid + 0.5)` then `%`/`/`); `slot_indirect_decode_naive` mirrors the ORIGINAL, un-rounded Q2
# decode (`mod`/`floor` straight off the float) so a gate can demonstrate the truncation defect it replaces.
static func slot_indirect_decode(fid: float, w: int) -> Vector2i:
	var f := int(fid + 0.5)
	return Vector2i(f % w, int(f / w))
static func slot_indirect_decode_naive(fid: float, w: int) -> Vector2i:
	var fx: float = fmod(fid, float(w))
	var fy: float = floor(fid / float(w))
	return Vector2i(int(fx), int(fy))

func _make_material() -> Material:
	# COSMOS ATMO-SKY A5: the absolute self-shaded globe shell v2 wins (supersedes the L3 terminator tint v1) —
	# sun_dir fed each frame via set_shell_absolute_sun_dir; the centre comes from MODEL_MATRIX (exact under scale).
	# Off → the shipped paths below verbatim (byte-identical; the shell is untouched).
	if CubeSphere.FP_SHELL_ABSOLUTE:
		var sh2 := Shader.new()
		# COSMOS LOD-TEXTURE Phase 1 (§1.3): pick the textured variant only when FP_FACET_TEX is on. Flag off ⇒
		# the shipped _SHELL_ABS_SHADER string VERBATIM (byte-identical material). base_map is bound later by
		# set_facet_tex (once the baker has built the array).
		# COSMOS LOD-TEXTURE Phase 4: the close-up shader variant wins when FP_FACET_TEX_CLOSEUP is on (it subsumes the
		# Phase-1 tex shader — a slot of −1 renders the identical base-map result). Off ⇒ the Phase-1 / shipped string.
		if _cu_on():
			sh2.code = _apply_block_detail(_SHELL_ABS_TEX_CU_SHADER)
		else:
			if CubeSphere.FP_SKIN_FLATCOLOR and CubeSphere.FP_BAND_BLOCK_MAP and CubeSphere.FP_FACET_TEX:
				sh2.code = _apply_flatcolor(_SHELL_ABS_TEX_SHADER)   # Minecraft per-block flat-colour map skin (no detail patterns)
			else:
				sh2.code = _apply_block_detail(_SHELL_ABS_TEX_SHADER) if CubeSphere.FP_FACET_TEX else _SHELL_ABS_SHADER
		# COSMOS TEXTURED-LOD V1 (FP_SHADE_UNIFIED): string-include the SHARED VoxiLight lighting law into the LIGHT head
		# (adds the moonshine floor + one uniform set), so the far skin shades IDENTICALLY to the near blocks. Off ⇒ the
		# shell code is returned verbatim (byte-identical). Applied outside _apply_block_detail — different string regions.
		sh2.code = _apply_shade_unified(sh2.code)
		# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2 (FP_SMOOTH_NORMAL_LIT): splice in the smooth-tile vertex-normal
		# lighting branch (the COLOR.a<0.5 discriminator — see cube_sphere.gd). Off ⇒ code returned verbatim.
		sh2.code = _apply_smooth_normal_lit(sh2.code)
		# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT, LAW S): resolve the live band/close-up
		# slot from the lookup texture instead of trusting UV2.y directly (which now carries the stable fid). Off ⇒
		# code returned verbatim (no anchor touched when v_slot/v_bslot don't even exist in this variant).
		sh2.code = _apply_slot_indirect(sh2.code)
		var sm2 := ShaderMaterial.new()
		sm2.shader = sh2
		sm2.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		# Unified: the ONE uniform set (values from VoxiLight — night_floor 0.06 == SHELL_NIGHT_FLOOR, moonshine floor).
		# Off: the shipped SHELL_NIGHT_FLOOR / TERMINATOR_MU (the moonshine set is a no-op — the shader has no such uniform).
		if CubeSphere.FP_SHADE_UNIFIED:
			sm2.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
			sm2.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
			sm2.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
		else:
			sm2.set_shader_parameter("night_floor", CosmosSky.SHELL_NIGHT_FLOOR)
			sm2.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
		if _cu_on():
			sm2.set_shader_parameter("cu_k", float(FacetAtlas.K))
			sm2.set_shader_parameter("cu_near", CubeSphere.CLOSEUP_NEAR)
			sm2.set_shader_parameter("cu_far", CubeSphere.CLOSEUP_FAR)
			var seed := PackedVector2Array()   # cu_facet reverse-map seeded to (-1,-1) — no facet resident yet
			seed.resize(CubeSphere.CLOSEUP_MAX)
			for i in range(CubeSphere.CLOSEUP_MAX):
				seed[i] = Vector2(-1.0, -1.0)
			sm2.set_shader_parameter("cu_facet", seed)
		# COSMOS TEXTURED-LOD U1: seed the band reverse-maps to sentinels (no band facet resident yet). band_map is bound
		# later by set_facet_band once the baker built the array; band_facet/band_n arrive via set_band_slots.
		if _bm_on():
			sm2.set_shader_parameter("band_k", float(FacetAtlas.K))
			if CubeSphere.FP_BAND_META_TEX:
				# FP_BAND_META_TEX: seed the reverse-map DATA TEXTURE (sentinel a=-1) so band_meta is never unbound.
				var mimg := Image.create(CubeSphere.band_layers(), 1, false, Image.FORMAT_RGBAF)
				mimg.fill(Color(-1.0, -1.0, 0.0, 0.0))
				sm2.set_shader_parameter("band_meta", ImageTexture.create_from_image(mimg))
			else:
				var bfacet := PackedVector2Array()
				var bn := PackedVector2Array()
				bfacet.resize(CubeSphere.BAND_LAYERS)
				bn.resize(CubeSphere.BAND_LAYERS)
				for i in range(CubeSphere.BAND_LAYERS):
					bfacet[i] = Vector2(-1.0, -1.0)
					bn[i] = Vector2(0.0, 0.0)
				sm2.set_shader_parameter("band_facet", bfacet)
				sm2.set_shader_parameter("band_n", bn)
			if CubeSphere.FP_SKIN_FLATCOLOR:
				var lut := PackedVector3Array()   # far_lut = frozen_colors() tile-mean palette (id->flat colour)
				for c in FarPalette.frozen_colors():
					lut.append(Vector3(c.r, c.g, c.b))
				sm2.set_shader_parameter("far_lut", lut)
		return sm2
	# COSMOS-LOD-SKY L3: the terminator-tint shell shader wins when its flag is on (it subsumes the plain lit
	# vertex-colour look; sun_dir is fed each frame via set_terminator_sun_dir). Off → the shipped paths verbatim.
	if CubeSphere.SHELL_TERMINATOR_TINT:
		var sh := Shader.new()
		sh.code = _SHELL_TINT_SHADER
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		return sm
	# TIER-DEPTH P3 (§5.2): the far ring is the coarsest overlapping tier → an 8-quantum window-space depth bias so it
	# loses every coincident-depth tie to the skin and near blocks at ANY distance. The biased material is a LIT
	# vertex-colour spatial shader equivalent to the StandardMaterial3D below (fog/tonemap applied by the environment).
	# Flag off → the shipped StandardMaterial3D verbatim (byte-identical).
	if TierPlace.depth_bias_on():
		return TierPlace.make_biased_material(TierPlace.far_bias())
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # far ring: winding-agnostic (transforms may flip facets)
	m.roughness = 1.0
	return m

## COSMOS-LOD-SKY L3: feed the current Sun direction into the shell tint shader's `sun_dir` uniform (main.gd forwards
## it from CosmosSky each frame). No-op unless SHELL_TERMINATOR_TINT is on and the material is the tint shader — so
## flag-off is byte-identical (the setter is never wired) and it can never touch the StandardMaterial/bias paths.
func set_terminator_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.SHELL_TERMINATOR_TINT or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)

## COSMOS ATMO-SKY A5 (FP_SHELL_ABSOLUTE): feed the current Sun direction into the shell v2 shader's `sun_dir`
## uniform each frame (main.gd forwards it from CosmosSky). The planet centre needs no uniform — the v2 shader
## reads it from MODEL_MATRIX so it is exact under the scaled placement. No-op unless the flag is on and the
## material is the v2 shader ⇒ flag-off is byte-identical (never wired; the StandardMaterial path is untouched).
func set_shell_absolute_sun_dir(sun_dir: Vector3) -> void:
	# COSMOS TEXTURED-LOD V1 (FP_SHADE_UNIFIED): also feed the sun when the biased-tier fallback material carries the far
	# ring (FP_SHELL_ABSOLUTE off, tier path) so its unified self-shade tracks the Sun. Off both flags ⇒ byte-identical.
	if not (CubeSphere.FP_SHELL_ABSOLUTE or CubeSphere.FP_SHADE_UNIFIED) or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)

## docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): feed the current Sun direction into the smooth-v2
## annulus's OWN ShaderMaterial (a separate material from the shell's — see facet_smooth_v2.gd's shader doc) so
## its day/night/terminator shade tracks live time. No-op with no smooth-v2 instance ⇒ byte-identical off.
func set_smooth_v2_sun_dir(sun_dir: Vector3) -> void:
	if _smooth_v2 != null:
		_smooth_v2.set_sun_dir(sun_dir)

## COSMOS LOD-TEXTURE Phase 1 (§1.3): bind the baker's 6-layer base map into the shell shader's `base_map`
## uniform. No-op unless FP_FACET_TEX is on and the material is the textured shader ⇒ flag-off is byte-identical
## (never wired; the shipped shader has no base_map sampler). Called once by WorldManager after the prewarm bake.
func set_facet_tex(tex: Texture) -> void:
	if not _tex_on() or _mi == null:
		return
	_skin_base_tex = tex                              # cache for set_skin_active (orbit §2V retire/restore)
	var mat := _mi.material_override
	if mat is ShaderMaterial and _skin_active:
		(mat as ShaderMaterial).set_shader_parameter("base_map", tex)

## COSMOS PLANET-LOD-CONFIG P0 (§2.4 — REPLACE, not overlay): retire / restore the smooth §2V skin. When the orbit
## megablock tier engages above the swap it OWNS the disc, so we UNBIND the base/band/close-up samplers on the far ring
## → the shell shader's texture weight collapses (tx.a≈0 ⇒ wt=0) and the far ring reads as the plain vertex-colour
## FarPalette backstop (round silhouette + rim intact, NO blotch) UNDER the crisp megablocks. On descent (`active` true)
## the cached textures are rebound → the shipped skin path resumes. Self-guards on _tex_on() ⇒ never called / inert with
## FP_BLOCK_LOD_ORBIT (or FP_FACET_TEX) off ⇒ byte-identical. Idempotent.
func set_skin_active(active: bool) -> void:
	if _skin_active == active:
		return
	_skin_active = active
	if not _tex_on() or _mi == null:
		return
	var mat := _mi.material_override
	if not (mat is ShaderMaterial):
		return
	var m := mat as ShaderMaterial
	m.set_shader_parameter("base_map", _skin_base_tex if active else null)
	if _skin_band_tex != null:
		m.set_shader_parameter("band_map", _skin_band_tex if active else null)
	if _skin_cu_tex != null:
		m.set_shader_parameter("closeup_map", _skin_cu_tex if active else null)

## COSMOS LOD-TEXTURE Phase 4: bind the baker's close-up Texture2DArray into the shell shader's `closeup_map`. No-op
## unless FP_FACET_TEX_CLOSEUP is on and the material is the close-up shader ⇒ flag-off is byte-identical (never wired).
func set_facet_closeup_tex(tex: Texture) -> void:
	if not _cu_on() or _mi == null:
		return
	_skin_cu_tex = tex
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("closeup_map", tex)

## COSMOS TEXTURED-LOD T1b: bind the shared detail atlas + the baker's id map into the shell shader's `detail_map` /
## `id_map` uniforms. No-op unless FP_BLOCK_DETAIL && the textured shader is live ⇒ flag-off is byte-identical (never
## wired; the shader string has no detail samplers). Called once by WorldManager after the prewarm bake.
func set_facet_detail(detail_tex: Texture, id_tex: Texture) -> void:
	if not (_tex_on() and CubeSphere.FP_BLOCK_DETAIL) or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("detail_map", detail_tex)
		(mat as ShaderMaterial).set_shader_parameter("id_map", id_tex)

## COSMOS LOD-TEXTURE Phase 4: push the baker's current slot map (fid→layer) + layer→(a,b) reverse-map. Main thread
## only (WorldManager, when the baker's epoch bumps). Updates the live `_closeup_slots` (frozen into the mesh at the
## next build) and the `cu_facet` shader uniform (read live per fragment). Requests a re-emit so the new slots reach
## the mesh's UV2.y. No-op with the flag off.
## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): the re-emit above is exactly R3.1.b's
## hitch engine — every close-up commit forcing a full front tri-soup rebuild purely to re-bake a UV2.y byte. Under
## the flag `_on_slot_map_changed` updates ONLY the tiny lookup texture instead (`_pending` never sets, `_shell_gen`
## never bumps for a slot-only change).
func set_closeup_slots(slots: Dictionary, facet_map: PackedVector2Array) -> void:
	if not _cu_on():
		return
	_closeup_slots = slots
	if _mi != null:
		var mat := _mi.material_override
		if mat is ShaderMaterial and facet_map.size() == CubeSphere.CLOSEUP_MAX:
			(mat as ShaderMaterial).set_shader_parameter("cu_facet", facet_map)
	_on_slot_map_changed()

## COSMOS TEXTURED-LOD U1 (§2U.1): bind the baker's band id map into the shell shader's `band_map` uniform. No-op unless
## the band tier is live and the material is the textured shader ⇒ flag-off is byte-identical (never wired). Called by
## WorldManager once the baker built the band array.
func set_facet_band(tex: Texture) -> void:
	if not _bm_on() or _mi == null:
		return
	_skin_band_tex = tex
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("band_map", tex)

## COSMOS TEXTURED-LOD U1 (§2U.1): push the baker's current band slot map (fid→layer) + the layer→(a,b) and layer→(Nx,Ny)
## reverse-maps. Main thread only (WorldManager, when the baker's band_epoch bumps): updates the live `_band_slots` (frozen
## into the mesh at the next build so UV2.y carries 64+layer) and the band_facet/band_n shader uniforms (read live per
## fragment), then requests a re-emit. No-op with the band tier off.
## FP_PLANET_MAP: bind the always-resident whole-planet fine tier array as the shell shader's fine_map. Called
## per-frame by WorldManager (cheap) so it survives far-ring material re-emits. No-op off the flag / no material.
func set_fine_map(tex) -> void:
	if not CubeSphere.FP_PLANET_MAP or _mi == null or tex == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("fine_map", tex)

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 3 Q2 (FP_SLOT_INDIRECT): same fix as `set_closeup_slots` — a band
## commit updates only the lookup texture under the flag, never re-emits.
func set_band_slots(slots: Dictionary, facet_map: PackedVector2Array, n_map: PackedVector2Array) -> void:
	if not _bm_on():
		return
	_band_slots = slots
	if _mi != null:
		var mat := _mi.material_override
		if mat is ShaderMaterial and facet_map.size() == CubeSphere.band_layers() and n_map.size() == CubeSphere.band_layers():
			if CubeSphere.FP_BAND_META_TEX:
				_push_band_meta(mat as ShaderMaterial, facet_map, n_map)
			else:
				(mat as ShaderMaterial).set_shader_parameter("band_facet", facet_map)
				(mat as ShaderMaterial).set_shader_parameter("band_n", n_map)
	_on_slot_map_changed()

## FP_BAND_META_TEX: pack (a,b,Nx,Ny) per band layer into the 512×1 RGBA32F reverse-map texture (one tiny update()),
## replacing the band_facet[]/band_n[] uniform arrays (which cap out at ~400 layers on ANGLE's fragment-uniform budget).
func _push_band_meta(mat: ShaderMaterial, facet_map: PackedVector2Array, n_map: PackedVector2Array) -> void:
	var n := CubeSphere.band_layers()
	if _band_meta_img == null:
		_band_meta_img = Image.create(n, 1, false, Image.FORMAT_RGBAF)
	for i in range(n):
		_band_meta_img.set_pixel(i, 0, Color(facet_map[i].x, facet_map[i].y, n_map[i].x, n_map[i].y))
	if _band_meta_tex == null:
		_band_meta_tex = ImageTexture.create_from_image(_band_meta_img)
	else:
		_band_meta_tex.update(_band_meta_img)
	mat.set_shader_parameter("band_meta", _band_meta_tex)                  # re-emit so UV2.y carries the new band slots (rides the existing deferred pipeline)

## COSMOS TEXTURED-LOD T1b gate surface (G-BD-OFF/TILE): the RAW textured shell shader string (no detail) and the
## FP_BLOCK_DETAIL-injected result, so the gate can assert byte-identity off and additive-only injection on, with the
## shader_type count unchanged (zero new compiled programs).
static func gate_tex_shader_raw(cu: bool) -> String:
	return _SHELL_ABS_TEX_CU_SHADER if cu else _SHELL_ABS_TEX_SHADER
static func gate_tex_shader_detail(cu: bool) -> String:
	return _apply_block_detail(_SHELL_ABS_TEX_CU_SHADER if cu else _SHELL_ABS_TEX_SHADER)

## COSMOS TEXTURED-LOD U1 gate surface (G-BB-OFF): the FP_BLOCK_DETAIL string with the band injection FORCED off vs on,
## so the gate can assert (a) band-off ≡ the shipped detail string (byte-identical), (b) band-on is ADDITIVE only (still
## exactly ONE shader_type → zero new compiled programs) and declares the band_map/band_facet samplers + v_bslot varying.
static func gate_band_shader(cu: bool, band: bool, shot := CubeSphere.FP_BAND_SHOT) -> String:
	return _apply_block_detail(_SHELL_ABS_TEX_CU_SHADER if cu else _SHELL_ABS_TEX_SHADER, band, shot)

## COSMOS LOD-TEXTURE Phase 4 gate (G-FT-SLOT): the emitted UV2 (face, slot) for facet `fid` in _emit_cached order.
## Empty unless FP_FACET_TEX is on. Reflects the CURRENT slot snapshot (call after a build/force_rebuild). Under
## Q2 (FP_SLOT_INDIRECT) this reflects the stable-fid payload instead (`_uv2_y`) — what the mesh ACTUALLY carries.
func gate_facet_uv2(fid: int) -> PackedVector2Array:
	if not _tex_on():
		return PackedVector2Array()
	# Build the per-facet uv2 the same way the emit does (face, current slot) so the gate reads the live mapping.
	var out := PackedVector2Array()
	var face: int = _tex_decode(fid)[0]
	var sv := Vector2(float(face), _uv2_y(fid))
	out.resize(96)
	for i in range(96):
		out[i] = sv
	return out

## COSMOS LOD-TEXTURE Phase 1 gate (G-FT-UV): facet `fid`'s tri-soup UVs (the emitted ARRAY_TEX_UV for that
## facet, in _emit_cached order). Empty unless FP_FACET_TEX is on. Lets the gate assert per-facet UV mapping +
## same-face neighbour continuity without dissecting the merged mesh.
func gate_facet_uvs(fid: int) -> PackedVector2Array:
	_ensure_tri_cached(fid)
	return _tri_uv_cache.get(fid, PackedVector2Array())

## COSMOS LOD-TEXTURE Phase 1 gate (G-FT-UV / G-FT-OFF): the committed ring surface's raw arrays (ARRAY_VERTEX,
## ARRAY_COLOR, ARRAY_TEX_UV, ARRAY_TEX_UV2, …). Empty when nothing is built. Read-only.
func mesh_arrays() -> Array:
	if _mi == null or _mi.mesh == null:
		return []
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return []
	return mesh.surface_get_arrays(0)

## Triangle count of the built ring mesh (gate).
func triangle_count() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var vv: Variant = arr[Mesh.ARRAY_VERTEX]
	return (vv as PackedVector3Array).size() / 3
