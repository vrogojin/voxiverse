class_name WorldManager
extends Node3D

# FP-FIXED-FRAME: preload the FrameAdapter (not the global class_name) so this always-parsed core script never
# depends on the stale editor class-cache (the same convention as FLM/FLB in verify_fp_m2). Used as a type below.
const _FrameAdapterCls := preload("res://src/world/frame_adapter.gd")
# COSMOS SEAMLESS-SCALES C3: preload the skin tier (not the class_name) for the same reason as _FrameAdapterCls —
# this always-parsed core must not depend on the editor class-cache. DEAD unless CubeSphere.FP_SKIN_TIER.
const _SkinTierCls := preload("res://src/world/facet_skin_tier.gd")
## Owns "the world": picks the rendering path, drives streaming, and exposes the
## analytic queries (solidity, surface height, voxel raycast) that the player and
## HUD use regardless of path. Also holds the decoupled sim layer (material
## registry + per-voxel environment) so gameplay reads simulation, not geometry.
##
## Path selection (DESIGN §2): if the Zylann godot_voxel module is compiled into
## the running engine (ClassDB has VoxelTerrain), use it; otherwise fall back to
## the pure-GDScript chunk streamer. Both render the same infinite grass hills
## from TerrainConfig, so everything downstream is identical.

signal path_selected(using_module: bool)

## Emitted when a cell's per-cell METADATA is DROPPED by a material change or break
## (VOXEL-DATA-STRUCTURE §14 P1 / §11): `_write_cell` settles the orphaned document
## through this signal so a future system (e.g. spilling a chest's contents as
## pickups) can react. No consumer is required today. Never fired by `set_state`
## (the one write that PRESERVES metadata) or by `set_metadata` (an explicit update).
signal block_entity_orphaned(cell: Vector3i, old_meta: Dictionary)

var environment: PerVoxelEnvironment
var materials: MaterialRegistry
var using_module: bool = false

# COSMOS M2 — the floating-origin chart (docs/COSMOS-PLANET-TOPOLOGY.md §3.1/§3.2). NULL in
# FLAT_WORLD (the default): the edit store keys by Vector3i window cell and every query is
# BYTE-IDENTICAL to the pre-M2 flat world. Non-null ONLY in curved mode (installed in _ready when
# CubeSphere.FLAT_WORLD is false, or injected by the M2 verify): the `_edits`/`_meta` overlays then
# key by the 43-bit GLOBAL edit key (§1.3) so an edit is found again by its global identity across
# any origin re-anchor or home face, and worldgen reads the window-independent GLOBAL cell (§8.2).
var _chart: CosmosChart = null

var _streamer: ChunkStreamer          # fallback path
var _module_world: Node3D             # godot_voxel path
var _ground: GroundCollider           # local blocky physics collider
# COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §2.1) — the play-frame bridge. `_active_frame` is the
# new ActiveFrame Node3D (@ identity in Phase 1) that hosts the player, GroundCollider and loose VoxelBody debris;
# `_frame` is the FrameAdapter every physics-boundary conversion routes through. When FP_FIXED_FRAME is off both are
# inert: `_active_frame` stays null, `_frame` is a transparent identity adapter, and `_frame_host()` returns self —
# so the scene tree and every numeric result are byte-identical to today. Created in _ready().
var _active_frame: Node3D = null
var _frame: _FrameAdapterCls = null
# COSMOS FP-FIXED-FRAME §2.3/§2.2 step 6 + §10 decision 2 (Phase 3) — PER-BODY PER-FACET-ACCURATE debris gravity.
# With the fixed frame ON the scene IS the planet-ABSOLUTE frame, so a VoxelBody's "down" is ITS OWN facet's up in
# absolute space (−T_fid.basis.y). Phase 2 used ONE global Area3D rotated to the active facet's up (≤3.7° error on a
# body resting on a neighbour facet); Phase 3 replaces it with ONE Area3D PER LIVE FACET (`_gravity_areas`: fid →
# Area3D), each a REPLACE-override box oriented to T_fid + placed over that facet's patch, so a body over facet F
# falls exactly along F's up. The set is BOUNDED to the live pool (active + ≤ POOL_MAX_NEIGHBOURS neighbours) — the
# NEVER-OOM cap — resynced on every crossing/pool change. `_gravity_vec` mirrors the ACTIVE facet's down for the
# headless gate. Empty/(-Y) when the fixed frame is off → default −Y gravity, byte-identical.
var _gravity_areas: Dictionary = {}   # fid -> Area3D (fixed-frame only; bounded to the live pool)
var _gravity_vec: Vector3 = Vector3.DOWN
# COSMOS FP-FIXED-FRAME re-anchor (§3 / §10 decision 1): the accumulated integer floating-origin shift applied to
# every ABSOLUTE node (PlanetRoot, far ring, per-facet gravity) AND folded into the ActiveFrame placement so the
# player/debris/collider/viewer ride it. `_player_abs_max` is the Phase-0 telemetry guard — the running max of the
# player's rendered-absolute magnitude (surfaced live via player_abs_max() → remote bridge). ZERO/0 when off.
var _anchor_offset: Vector3 = Vector3.ZERO
var _player_abs_max: float = 0.0
var _grav_sync_accum := 0.0           # throttle for the per-facet gravity resync (fixed-frame only, §10 decision 2)
var _far: FarTerrain                  # far-distance analytic heightmap layer (LOD-DESIGN); null when disabled
var _facet_ring: FacetFarRing         # COSMOS FACETED §5.2: the planet rendered around the active facet (faceted mode)
var _skin: Node3D = null              # COSMOS SEAMLESS-SCALES C3: the heightfield skin tier; null unless FP_SKIN_TIER
var _facet_tex: FacetTexBaker = null  # COSMOS LOD-TEXTURE Phase 1: per-facet baked far texture; null unless FP_FACET_TEX
# COSMOS-BACKGROUND-PREBAKE (FP_BG_PREBAKE): last update_streaming call's Time.get_ticks_usec(), for the
# real measured wall-clock frame-ms passed to _facet_tex.update() (see that call site's doc comment).
var _bg_last_frame_usec := 0
var _relief_data: GlobalReliefData = null   # COSMOS-FAR-GEOMETRY-PREBAKE (task #99): whole-planet coarse height DEM
                                             # + sun-agnostic hillshade; null unless FP_GLOBAL_RELIEF_DATA
# Independent of _bg_last_frame_usec (same measurement discipline, own clock — G2 must pace even when _facet_tex
# doesn't exist, e.g. FP_GLOBAL_RELIEF_DATA on without FP_FACET_TEX/FP_SHELL_ABSOLUTE).
var _g2_last_frame_usec := 0
var _relief_settled := false                 # FP_DEM_DEFER (COSMOS-STREAM-PARALLEL Phase A): latched once the near view
                                             # meshes (mark_settled fired) — before then the DEM bake is deferred.
var _load_settled := false                   # FP_LOAD_DEFER (COSMOS-FAST-LOAD Phase 1): the ONE fresh-load settle latch.
                                             # Flipped once off initial_view_meshed (or the failsafe) — before then the
                                             # far-ring smooth-v2 commits, env warm-converge, and snow step are deferred.
var _load_defer_start_ms := -1               # FP_LOAD_DEFER: wall-clock anchor for LOAD_DEFER_FAILSAFE_MS (set on first update_streaming).
var _block_lod: FacetBlockLodRing = null  # COSMOS BLOCK-LOD P1: L1 megablock rim ring; null unless FP_BLOCK_LOD
var _block_lod_ladder: FacetBlockLodLadder = null   # COSMOS BLOCK-LOD P2: L2..L4 streamed ladder; null unless FP_BLOCK_LOD_RINGS
var _block_lod_global: FacetBlockLodGlobal = null   # COSMOS BLOCK-LOD P2: L5 GLOBAL always-resident tier; null unless FP_BLOCK_LOD_GLOBAL
var _block_lod_orbit: FacetBlockLodOrbit = null     # COSMOS PLANET-LOD-CONFIG P0: crisp orbit megablock disc; null unless FP_BLOCK_LOD_ORBIT
var _orbit_skin_retired := false                    # latch: §2V skin currently suppressed on the far ring (orbit engaged)
var _tex_slots_epoch := -1            # COSMOS LOD-TEXTURE Phase 4: last close-up slot epoch pushed to the ring (−1 = never)
var _tex_band_epoch := -1             # COSMOS TEXTURED-LOD U1: last band slot epoch pushed to the ring (−1 = never)
var _lod_excl_accum := 0.0            # FP-M2b: throttle the far-ring/LOD exclusion resync (covered set grows as builds apply)
# FP-M2c (docs/COSMOS-FP-M2-DESIGN.md §6.5): the closed-loop load-adaptive admission controller. OWNED here, wired
# to the LIVE measured-load source, forwarded to module_world (→ FacetLodMesher grants/apply + the pool ramp pace),
# and ticked every frame with real time. null unless FP_M2_LOD + the module path (dead code with the flag off).
var _load_ctrl = null
const FACET_WALL_EPS := -3.0          # COSMOS FACETED §6.1: FP3 removes the FP2 ridge wall — the crossing handoff
                                      # replaces it. A deep backstop (3 blocks PAST the ridge) only catches a
                                      # failed crossing so the player can never wander far onto masked air.
const FACET_CROSS_HYST := 0.1         # COSMOS FACETED §6.1: cross onto the neighbour just past a ridge (fires in
                                      # update_streaming the same frame the feet pass P, so any speed is caught)
# FP-S1(c) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R3 / §8): a crossing that lands the reframed player PAST
# one of the destination facet's OTHER ridges (the near-corner case) would re-fire a full teardown+restream every
# physics tick (B→C→B…) — the "all chunks blank" storm. Two guards: a containment check (only commit a crossing
# whose landing is interior to ALL FOUR of B's ridges, i.e. would not itself immediately re-fire) and a short
# cooldown (a crossing cannot re-fire for the next N maybe_cross_facet calls — belt-and-suspenders vs ridge jitter).
const FACET_CROSS_COOLDOWN := 6       # maybe_cross_facet calls (≈physics ticks) suppressed after a committed crossing
var _cross_cooldown := 0              # remaining suppressed calls (decremented per call; 0 = ready)
const FACET_CORNER_SLACK := 2.0       # COSMOS FS-W (§3): a corner-commit landing may be up to this far past one of the
                                      # destination's ridges (a genuine 3-facet corner) and still commit — kept < |WALL_EPS|
                                      # (3) so the player is always placed clear of the −3 ridge wall (never stranded).

# COSMOS UP-VECTOR FACET-DESYNC FIX (FP_UPVECTOR_FACET_HEAL, docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md
# §2): the strip's own guards. MAX_SPEED (b/s) — the strip is only a trap for a near-stationary player; a walker
# crosses it in one physics step, so gating on speed means normal walking never even evaluates the mask check.
# NEAR_RIDGE — derived: max seam-plane |B| (0.0332) × (the live FP_DATUM_BAKE lift ceiling 6.9 + 1) ≈ 0.26,
# rounded up for margin — beyond this no crossing-law/mask disagreement is geometrically possible (doc §1.2).
const UPVECTOR_HEAL_MAX_SPEED := 0.5
const UPVECTOR_HEAL_NEAR_RIDGE := 0.3

# FP-M1c Planet Assembly pool policy (docs/COSMOS-FP-M1-DESIGN.md §4.3). Amortization throttle (≤1 spawn AND ≤1
# retire per POOL_SPAWN_INTERVAL_S) + the pool-miss counter (a re-designation crossing whose destination was not
# yet pooled falls back to the FP-S1 teardown — must be ~0 in a normal walk; the gate asserts it). All dormant
# unless CubeSphere.FP_M1_POOL. Wall-clock (Time.get_ticks_msec) so it works both live and in headless soaks.
var _last_pool_spawn_ms := -100000
var _last_pool_retire_ms := -100000
var _pool_miss_count := 0             # re-designation POOL-MISS fallbacks (gate: 0 in a normal walk)
# FP_NB_FULLRES (docs/COSMOS-NB-FULLRES-DESIGN.md §2) — the widened-pool state. All inert (false / -1 / empty) with
# CubeSphere.FP_NB_FULLRES off ⇒ byte-identical to the shipped FP-M2d residency law. `_nb_settled` latches the first
# time the near view is meshed (initial_view_meshed) — widening never begins during the fresh-load window. `_nb_b0_bytes`
# is the measured post-settle byte baseline (voxel_used + static heap) snapshotted at that latch; the ledger enforces a
# GROWTH budget over it (NEVER-OOM, measured counters only). `_nb_breached` is the ledger-breach hysteresis latch (set at
# the cap, cleared below cap − REHYST). `_nb_excl_latch` (fid→true) records which live neighbour's seam BAND has meshed —
# only those (plus the imminent) are excluded from the far ring (band-conditional exclusion, §2.4 CORRECTION 2), so a
# live-but-empty neighbour keeps its far tile (no see-through hole). `_nb_imminent_fid` is the last-known imminent (the
# exclusion reads it outside the pool pass). `_last_nb_retire_ms` paces the breach-ladder LRU/farthest retire.
var _nb_settled := false
var _nb_b0_bytes := -1
var _nb_breached := false
var _nb_excl_latch := {}
var _nb_imminent_fid := -1
var _last_nb_retire_ms := -100000
var _nb_fullres_active := false       # last pool pass's nb_fullres_on() decision (drives the band-conditional exclusion + skin outside the pass)
# COSMOS-PERF UNATTENDED R3 (FP_ALT_REGIME, §0-W3/§5): the altitude regime latch. `_alt_orbital` is true while the
# player is above the ATMO_TOP gate (ORBITAL — the near field is frozen: no per-tick redesignation / pool-manage /
# snow / shrink-snap); it flips with ALT_REGIME_HYST hysteresis in _update_alt_regime (driven from update_streaming).
# `_alt_reentry_pending` is armed on the ORBITAL→SURFACE transition and consumed by the very next maybe_cross_facet to
# do the ONE restore redesignation onto the true sub-camera facet. `_alt_redesignate_count` (test-visible) counts those
# restores. All three are inert (false/0, never read) with FP_ALT_REGIME off ⇒ byte-identical.
var _alt_orbital := false
var _alt_reentry_pending := false
var _alt_redesignate_count := 0
# COSMOS SEAMLESS-TRANSITION S1 (FP_APPROACH_ANCHOR, §3): the ground-anchored-viewer state. `_anchor_released` is the
# hysteretic release latch (true past ANCHOR_REL_HI, false again below ANCHOR_REL_LO/ANCHOR_HYST) — it selects the
# ramp's lower knee so ascent releases at REL_LO while descent re-grows to full only below REL_LO/HYST (no flap).
# `_anchor_last_write_ms` debounces the two viewer writes (offset + view_distance) to ≥ ANCHOR_WRITE_DEBOUNCE_MS. All
# inert (never read; no writes issued) with FP_APPROACH_ANCHOR off ⇒ byte-identical.
var _anchor_released := false
var _anchor_last_write_ms := -100000
# A1 CROSSING INSTRUMENTATION (#114): a bounded FIFO of per-crossing attribution records built in maybe_cross_facet
# and drained by RemoteBridge (take_crossing_events) to publish over the telemetry socket. Only APPENDED on an actual
# committed crossing (seconds apart), so it is normally empty and adds no per-frame cost; bounded so a drain-less
# session can never grow it without limit (NEVER-OOM). Untouched when FACETED is off → FLAT byte-identity holds.
var _crossing_events: Array = []
const CROSSING_EVENTS_MAX := 32       # hard cap; oldest dropped past this (a bridge drains ~60/s — never reached live)
# FP-M2d (§9.1): fids whose live promote is in flight (fid -> spawn ms). Each frame their seam-side band is polled
# (pool_seam_meshed); when meshed — or after CubeSphere.PROMOTE_EVICT_MAX_S — the held LOD cover is evicted (lod_evict),
# so the LOD mesh overlaps the streaming terrain with NO gap and is dropped only once the full-res seam is up. FP_M2_LOD-only.
var _promote_pending: Dictionary = {}
var _last_demote_relief_ms := -100000  # W3: throttle sustained-overload LOD demote relief to ≤1 per CTRL_TICK_S (else
                                       # _process fires it every frame while demote_pressure() holds → coarsens the whole
                                       # LOD field to max tier in ~1s and pulses coarse↔fine)

# COSMOS M4 (§5.1): true while a home-face flip's near field is restreaming (MODULE path only). Set in
# maybe_flip_home_face, cleared in update_streaming once the module reports ramp_done() — at which point
# player edits are re-mirrored into the fresh terrain (§5.4) and the far handoff turbo is ended. Never set
# in FLAT_WORLD (no chart → no flip) or on the fallback path (it re-reads the overlay when it remeshes).
var _flip_settling := false

# COSMOS R2.2 (docs/…-REAL-GEOMETRY §1): the frozen-per-epoch bake frame shared by the near C++ mesher and
# the far layer, plus its anchor. Empty until m5_real_install_epoch runs (curved + M5_REAL). The near/far
# geometry is baked STATIC in this frame; the per-frame rigid F (alignment_transform) rotates it to render
# around the window-space camera. Re-installed at each home-face flip.
var _epoch_frame: Dictionary = {}
# COSMOS M5c (§4/§5): the player's raw distance to the nearest cube vertex, stashed by maybe_flip_home_face
# each frame so the §5 anomaly check reuses it. 1e30 = "not near a corner / flag off".
var _corner_dist := 1.0e30
var _epoch_anchor: Vector3 = Vector3.ZERO

# COSMOS-CORNER-CANONICAL (#69) companion — the TOPOLOGY §5.3 edit-lock. SEPARABLE: set false (or delete
# this const + the guard in _write_cell) to drop it. When true, a write to a corner-quadrant window cell
# (double-out on the active chart) is REFUSED — the wedge is a per-window sampling of the canonical
# terrain (COSMOS-CORNER-CANONICAL §4.2/§4.3), so an edit there has no stable window identity to
# re-mirror (unfold_to_window returns not-found for the quadrant). Curved-only (guarded on `_chart`), so
# FLAT_WORLD stays byte-identical. Entangled with corner gate (c4): c4 checks store+read when this is
# false and refusal when true.
const CORNER_EDIT_LOCK := true

# The dormant-by-default snowfall SIMULATION (SNOW-ACCUMULATION Decision 4). Owned here and stepped from
# `_process` on the MAIN thread; it grows/melts the variable-height snow around the player by writing
# through the ONE choke point (`_write_cell` → `_edits`), so its output is persisted exactly like a
# break/place edit. It is INERT until the player's position has been reported at least once (so it never
# runs during the frozen prewarm, or in a headless world that has no player).
var _snowfall: SnowfallSystem
# COSMOS CLIMATE W1: the coarse prognostic weather grid (null unless FP_CLIMATE_GRID). Stepped from
# _process on the main thread; PerVoxelEnvironment reads it. `_cosmos_clock` (injected by main.gd) gives
# the game-time for insolation/seasons; null ⇒ the grid runs on its own default dt (still a valid diurnal
# cycle once the clock exists). Both null in the shipped flat game ⇒ zero cost.
var _weather: WeatherSystem
# FP_WEATHER_THREAD: the dedicated weather WORKER thread (null unless the flag is on). Once the static basis
# is built on the main thread, the sweep is handed to this worker (EnvSimWorker) so the per-frame main-thread
# cost collapses to a swap check. Stopped/joined in _exit_tree (no dangling thread on scene exit).
var _weather_worker: EnvSimWorker = null
# COSMOS MAIN-THREAD ORCHESTRATION TH0 (FP_JOB_LANE): the ONE priority job lane every future offload dispatches
# COMPUTE through (onto the existing WorkerThreadPool, no new thread) and gets a bounded main-thread commit back.
# Constructed + pumped ONLY under the flag; null ⇒ the shipped main-thread path, byte-identical. TH0 routes
# NOTHING through it yet — it is the infrastructure TH1+ build on. `main_commit_ms` telemetry reads its drain time.
var _job_lane: JobLane = null
var _cosmos_clock: CosmosEphemeris.CosmosClock = null
var _weather_us_max := 0
var _last_player_pos: Vector3 = Vector3.ZERO
var _have_player_pos: bool = false
var _stream_tail_frame := -1            # FP_STREAM_TICK_ONCE: the last Engine.get_process_frames() the orchestration tail ran
var _dbg_tail_runs := 0                 # FP_STREAM_TICK_ONCE gate: cumulative orchestration-tail executions (read-back)
func debug_tail_runs() -> int: return _dbg_tail_runs
func debug_set_tail_frame(f: int) -> void: _stream_tail_frame = f   # gate-only: simulate a render-frame change (get_process_frames advances)

## COSMOS-MOTION-PHYS §6.5 (FP_MOVE_PROBE_CACHE) A/B readback: since-last-read window counts of generated-branch
## queries and cache hits (the §6.5 accept ratio n_probe_hit/n_probe_cva ≥ 0.5), plus current epoch size. Reading
## resets the window so the telemetry sample reflects the last snapshot interval (motion vs rest read distinctly).
## Returns {} with the flag off (never written) → byte-identical telemetry, exactly like fall_timing().
func gen_cache_stats() -> Dictionary:
	if not CubeSphere.FP_MOVE_PROBE_CACHE:
		return {}
	var out := {"n_probe_cva": _gen_cache_cva, "n_probe_hit": _gen_cache_hit, "gen_cache_sz": _gen_cache.size()}
	_gen_cache_cva = 0
	_gen_cache_hit = 0
	return out
# FP_ENV_FALL_HOLD: position-based downward-speed estimate (blocks/s, EMA) to pause the far-ring env-warm during a
# fast descent. Position-based so it works in every locomotion regime (incl. the rails coast that zeroes velocity).
var _fall_last_usec: int = -1
var _fall_vy_ema: float = 0.0
# T2f (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-consumer main-thread attribution. The WORST single-frame cost (usec)
# of the snowfall fixed step + the load-controller tick since the last telemetry drain; RemoteBridge samples the max once
# per window (take_perf_attrib) so the 0.5 s snowfall spike is attributed instead of folded anonymously into worst_ms.
var _snow_us_max := 0
var _ctrl_us_max := 0
# CROSSING-FASTGEN obs-2 fix (3): the EMA'd player speed (blocks/s), measured from the inter-update position delta and
# consumed ONLY under FP_VEL_PREDICT to lead the imminent promote/commit distances. Computed lazily inside its flag gate
# in update_streaming, so with the flag off it stays 0 and this is a literal no-op (no behaviour change, no read path).
var _player_speed: float = 0.0
var _last_stream_usec: int = -1

# Terrain edit overlay: the gameplay source of truth (floor + raycast + collider +
# collapse consult it), mirrored into whichever render path runs. This one
# dictionary replaces the old `_removed` set: 0 = dug to air, >0 = solid cell.
# Values are PACKED cell values (CellCodec: material | modifier<<16 | state<<32);
# a bare block id is a valid packed value meaning "full cube, state 0", so every
# value stored today is already canonical and no migration is needed. 0 stays
# "dug to air". `cell_value_at(cell)` = edits-overlay-else-generated is THE cell
# query; `block_id_at` is its material projection.
var _edits: Dictionary = {}           # Vector3i -> int packed cell value (0 = air)
# Per-column edit INDEX (PERF, GroundCollider fast path): the set of columns Vector2i(x, z)
# that have ANY overlay entry (dug or placed). Edits never leave `_edits` (a dug cell stays
# as value 0), so this only grows — maintained in the single write choke point. The collider
# skips its per-cell overlay scan on columns absent here (their overlay is empty), collapsing
# the region's ~30k Vector3i lookups to the handful of genuinely-edited columns.
var _edit_columns: Dictionary = {}    # Vector2i(x, z) -> true
# COSMOS-PERF UNATTENDED R5 (FP_EDIT_FID_INDEX): the INCREMENTAL per-facet edit index. Maps a facet id to the SET of
# `_edits` keys authored on it (fid -> {edit_key -> true}). Maintained in the single write/erase choke points
# (`_write_cell` adds, `sim_revert_cell` removes) under FACETED, so a crossing's `_rebuild_window_indices` +
# `_translate_active` touch ONLY the incoming facet's edits (O(active-fid)) instead of rescanning the whole `_edits`
# dict (O(all edits) — up to ~200 k snow cells). A byte-exact subset of `_edits` (same choke points). Empty + unused
# with the flag off (byte-identical) or under FLAT/curved (non-int keys carry no fid — those paths keep the full scan).
var _edits_by_fid: Dictionary = {}    # int fid -> Dictionary(edit_key:int -> true)
# docs/COSMOS-STRUCTURES-DESIGN.md (P0, FP_STRUCT_DETECT): incremental player-structure detection over PLACED overlay
# cells, driven from the two write choke points (_write_cell / sim_revert_cell). Constructed in setup() under the
# flag; null off (the choke-point hooks are one null test) ⇒ byte-identical. See structure_tracker.gd.
var _structure_tracker = null
# The number of edit keys the LAST `_rebuild_window_indices` iterated (the O() the crossing paid): == the active
# facet's edit count with FP_EDIT_FID_INDEX on, == the total edit count with it off. Read by verify_edit_fid_index.gd.
var _rebuild_scanned: int = 0
# COSMOS-PERF FALL (FP_FLOOR_BOUNDED): the number of `cell_value_at` scan iterations the LAST `floor_under` call ran.
# Read by verify_floor_bounded.gd to prove the fall scan is altitude-INDEPENDENT (≤ ~2·MARGIN, not ∝ feet-y). Pure
# introspection — never read by gameplay, carries no world state (does not affect the byte-identical off contract).
var _floor_scan_iters: int = 0
# Per-cell METADATA store (VOXEL-DATA-STRUCTURE §4.1): a SECOND sparse dict holding
# ONLY the rare cells that carry a block-entity document (container inventory, sign
# text, …). It carries NO occupancy/solidity semantics (rule-1 objection answered) —
# it is settled by the same write choke point and NEVER queried for "what's solid".
# The zero-cost-default guarantee: a metadata-free world keeps this EMPTY (O(1), zero
# per-cell cost), and `_write_cell` skips it entirely while it is empty. Main-thread,
# lifecycle-locked: only set_metadata (write) / break/place/collapse (settle) touch it.
var _meta: Dictionary = {}            # Vector3i -> Dictionary (JSON-subset document)
# Per-column monotonic high-water mark of the highest y ever PLACED (breaking a
# placed block does NOT lower it). Only bounds the collider's above-surface scan.
var _placed_top: Dictionary = {}      # Vector2i(x, z) -> int
# COSMOS-PERF FALL (FP_FLOOR_MEMO): per-WINDOW-column memo of the CELL index of the topmost solid-with-air-above
# (floor_under's answer seen from above all solids). Lets a repeated fall column resolve floor_under in O(1) instead
# of re-scanning ~MARGIN cold-generator cells every frame. INVALIDATED at the write/remap choke points (_write_cell,
# sim_revert_cell erase the column; _rebuild_window_indices clears; _shift_window_bookkeeping re-keys). Capped at
# FLOOR_MEMO_CAP and cleared wholesale on overflow (NEVER-OOM). Empty + unread with FP_FLOOR_MEMO off (byte-identical).
var _floor_top: Dictionary = {}       # Vector2i(x, z) -> int (topmost standable CELL y)
const _FLOOR_MEMO_NONE := -0x40000000 # sentinel: no memo for this column (never a real floor cell)
# COSMOS-MOTION-PHYS §6.3 (FP_MOVE_PROBE_CACHE): per-physics-tick generated-value cache under cell_value_at, keyed by
# the Vector3i window cell → packed generated value (≥ 0, so -1 is a safe miss sentinel). Consulted only AFTER the live
# edit-overlay get and only on the main thread; self-clears when the physics frame advances (_gen_cache_tick), and is
# cleared wholesale at the two remap choke points FP_FLOOR_MEMO patrols. Empty + untouched with the flag off.
var _gen_cache: Dictionary = {}        # Vector3i cell -> int packed generated value (this epoch only)
var _gen_cache_tick: int = -1          # Engine.get_physics_frames() the cache is stamped for (transient epoch)
var _gen_cache_cva: int = 0            # generated-branch queries this window (main-thread, flag-on) — A/B readback
var _gen_cache_hit: int = 0            # of those, cache hits — n_probe_hit/n_probe_cva is the §6.5 accept ratio
# Sparse per-joint reinforcement (glue/weld/cement; STRUCTURAL-INTEGRITY §4.2/§7):
# canonical key Vector4i(min_cell.x, .y, .z, axis) -> reinforcement id. Lives
# OUTSIDE the four cell axes (it is per-FACE, not per-cell). The structural solver
# reads it via `joint_mod`; breaking a block leaves stale entries harmless (a joint
# with a missing cell is never queried).
var _joint_mods: Dictionary = {}      # Vector4i -> int reinforcement id

# BOOT-LOAD PROFILE (perf/voxiverse-load-profile): running timestamp for the world_build SUB-phase timing below, so a
# fresh load breaks the ~114s world_build into wb_module_setup (the ~23s manifest bake) / wb_setup_mid / wb_farring (the
# ~90s far-ring cache) / wb_rest. Pure Time.get_ticks_msec() deltas + one print/console.log each — no per-frame cost.
var _wb_last := 0

## BOOT-LOAD PROFILE: emit one world_build sub-phase duration (ms since the previous wb mark). Same [BOOT] format as
## main.gd's boot phases so they interleave in the console. Called a handful of times inside _ready only.
func _wb_mark(phase: String) -> void:
	var now := Time.get_ticks_msec()
	var dt := now - _wb_last
	_wb_last = now
	print("[BOOT] %s %d ms" % [phase, dt])
	if OS.has_feature("web"):
		JavaScriptBridge.eval("console.log('[BOOT] %s %d ms');" % [phase, dt], true)

func _ready() -> void:
	_wb_last = Time.get_ticks_msec()
	environment = PerVoxelEnvironment.new()
	materials = MaterialRegistry.build_default()
	SurfaceModel.ensure_ready()
	BlockCatalog.ensure_ready()

	# COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §4): ensure the facet atlas is built and the spawn facet is
	# the active facet BEFORE the render path's generator is created (it freezes active_facet). main.gd does
	# this too, but a headless WorldManager (verify) is constructed directly — warm_up + set_active_facet are
	# idempotent, so this is a safe backstop. Default OFF → skipped, flat game unchanged.
	if CubeSphere.FACETED:
		TerrainConfig.warm_up()
		FacetAtlas.warm_up()
		if TerrainConfig.active_facet() < 0:
			TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())

	# COSMOS M2 (§3.1/§3.2): in curved mode install the floating-origin chart on the home face at
	# the identity origin, so the overlay keys globally and the origin can re-anchor as the player
	# walks. FLAT_WORLD (the default) leaves `_chart` null → Vector3i keying → byte-identical.
	if not CubeSphere.FLAT_WORLD:
		_chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
		TerrainConfig.set_active_frame(_chart.face, CubeSphere.d4_of(_chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1): atomic face+M_win
		environment.set_chart(_chart)
		_m5_sync_frame()   # COSMOS M5a: push the chart table to the true-position shader (no-op when M5_RENDER off)

	if ClassDB.class_exists("VoxelTerrain"):
		_setup_module_path()
	if not using_module:
		_setup_fallback_path()
	# BOOT-LOAD PROFILE: the render-path setup — on the module path this is where module_world.setup()'s ~23s appearance-
	# manifest bake lands (its own "setup timing: … manifest=…ms" print is a sub-total of this).
	_wb_mark("wb_module_setup")

	# COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §2/§7 P1): install the play-frame bridge. When the
	# flag is on, ActiveFrame is a Node3D @ IDENTITY (Phase 1) that hosts the player, GroundCollider and loose
	# VoxelBody debris; the FrameAdapter routes every physics-boundary conversion (a no-op at identity). When off,
	# `_active_frame` stays null and `_frame` is a transparent identity adapter → the tree + numerics are unchanged.
	_frame = _FrameAdapterCls.new()
	if _fixed_frame_on():
		_active_frame = Node3D.new()
		_active_frame.name = "ActiveFrame"
		# Phase 2 (§2.1): the ActiveFrame sits at the active facet's TRUE absolute transform T_active, so the player /
		# collider / debris hosted under it render + physic in planet-absolute space while their LOCAL transforms stay
		# facet-lattice. PlanetRoot is pinned @ identity forever (module_world), so a crossing only re-writes THIS node
		# (O(1) — ~10 non-terrain children), never the mesh blocks. (At Phase-1 sed toggles this reduces to identity when
		# the spawn facet's transform is identity; the P2 gates assert the tilted-frame behaviour instead.)
		_active_frame.transform = _anchored(FacetAtlas.facet_transform(TerrainConfig.active_facet()))
		add_child(_active_frame)
		# Per-facet directional-gravity Area3D volumes (§10 decision 2) so debris fall along THEIR OWN facet's absolute
		# up, not one global −T_active.basis.y. Built for the live pool now (active facet); resynced on crossings + the
		# throttled _process pass as neighbours spawn/retire — the set stays bounded to the pool (NEVER-OOM).
		_sync_gravity_areas()
	_frame.setup(_active_frame)

	# Local terrain physics collider (both render paths are collider-less). Hosted under ActiveFrame when the fixed
	# frame is on (its lattice-coord box shapes then acquire correct absolute globals through the parent, §4).
	_ground = GroundCollider.new()
	_ground.name = "GroundCollider"
	_frame_host().add_child(_ground)
	_ground.setup(self)

	# The snowfall sim reads/writes the SAME overlay + generation both render paths derive from, so it is
	# path-agnostic. It is created here but stays inert until the player reports a position (see _process).
	_snowfall = SnowfallSystem.new()
	_snowfall.setup(self)

	# COSMOS MAIN-THREAD ORCHESTRATION TH0 (FP_JOB_LANE): construct the priority job lane (SnowfallSystem-style —
	# ONLY under the flag, so off ⇒ the class is not even instantiated ⇒ zero bytes / zero CPU, byte-identical).
	# It dispatches onto the EXISTING WorkerThreadPool (≤2 slots, no new thread) and is pumped each frame from
	# _process. TH0 routes NOTHING through it yet; it is the foundation TH1+ (tex bake / far-ring warm / manifest)
	# hand their compute to. `main_commit_ms` telemetry reads its bounded main-thread drain time.
	if CubeSphere.FP_JOB_LANE:
		_job_lane = JobLane.new()

	# COSMOS CLIMATE W1 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §1.5): the ONE coarse prognostic weather grid.
	# Owned + stepped here exactly like SnowfallSystem (SnowfallSystem-style: constructed ONLY under the flag,
	# so all flags off ⇒ the class isn't even instantiated ⇒ zero bytes / zero CPU). PerVoxelEnvironment READS
	# it (engine rule 2). The static basis is built sliced over startup frames (§1.7); the game_time it needs
	# for insolation is injected via the celestial clock (main.gd → set_cosmos_clock). Default OFF → byte-identical.
	if CubeSphere.FP_CLIMATE_GRID:
		_weather = WeatherSystem.new()
		_weather.setup()
		environment.set_weather(_weather)
		# FP_WEATHER_THREAD: create (but do not yet start) the weather worker. It is started from _process
		# only once the static basis is fully built on the main thread (build_init is sliced over startup),
		# so the thread never races the one-time basis construction. Flag off ⇒ null ⇒ the main-thread path.
		if CubeSphere.FP_WEATHER_THREAD:
			_weather_worker = EnvSimWorker.new(_weather)
	# Far-distance terrain layer (LOD-DESIGN): render-only, collision-free, voxel-worker-free —
	# part of "the world" WorldManager owns. Path-agnostic (it reads only TerrainConfig/BlockCatalog/
	# ClimateModel), so it runs identically over the module world, the GDScript fallback and headless.
	# Gated on the single ENABLED const: false → no node, today's behaviour bit-for-bit.
	# COSMOS FACETED (§5.2): replace FarTerrain (the flat/curved global-index heightmap — a giant misplaced
	# sheet under a single facet) with the facet far ring: the whole planet rendered around the active facet.
	# BOOT-LOAD PROFILE: the collider/snow/weather setup between the manifest and the far ring.
	_wb_mark("wb_setup_mid")
	# docs/COSMOS-STRUCTURES-DESIGN.md (P0, FP_STRUCT_DETECT): the player-structure tracker is WorldManager-owned and
	# driven from the two write choke points — independent of the far ring (detection works even if rendering is off).
	# Only under FACETED with no chart (the edit keys are the (fid, cell) ints the tracker keys on). Off ⇒ null (byte-off).
	if CubeSphere.FP_STRUCT_DETECT and CubeSphere.FACETED and _chart == null:
		_structure_tracker = StructureTracker.new()
	if CubeSphere.FACETED and FacetFarRing.ENABLED:
		_facet_ring = FacetFarRing.new()
		_facet_ring.name = "FacetFarRing"
		add_child(_facet_ring)
		_facet_ring.setup(TerrainConfig.active_facet())
		# docs/COSMOS-FAR-TREES-DESIGN.md (P2, FP_FAR_TREES_FADE §5.5): hand the far-tree tier the edit-overlay chop
		# query so a chopped tree never reappears as a far card/mesh. Self-guards (no far-trees instance / flag off ⇒
		# the Callable is stored but never consulted) ⇒ byte-identical off.
		if CubeSphere.FP_FAR_TREES:
			_facet_ring.set_far_trees_chop_query(Callable(self, "far_tree_chopped"))
			# docs/COSMOS-FOREST-FPS-DESIGN.md (§4, FP_FAR_TREES_DELTA): hand the tier the edit-revision query so a
			# fresh chop re-arms its rebuild-on-change gate within one step. Stored like the chop query; only read
			# under the flag ⇒ byte-identical with FP_FAR_TREES_DELTA off.
			_facet_ring.set_far_trees_edits_rev_query(Callable(self, "edit_count"))
			# docs/COSMOS-FARTREE-ALIGN-DESIGN.md (§5.5, FP_FAR_TREES_NEARCULL): hand the tier the shared near-presence
			# query (NearPresence.covered, bound to the module world) so the far impostor is culled exactly where the
			# near blocky tree renders. Stored like the chop query; only read under FP_FAR_TREES_NEARCULL ⇒ byte-off.
			_facet_ring.set_far_trees_near_query(Callable(self, "far_tree_near_presence"))
			# docs/COSMOS-STRUCTURES-DESIGN.md (P0, FP_STRUCT_FAR): hand the far-structure tier the registry (the
			# StructureTracker), the PLACED-overlay sampler (structure_cell_at — the structure alone, no terrain slab),
			# the edit-revision query, and the SHARED near-presence predicate (reused verbatim from the far-trees cull).
			# Stored like the tree queries; only consumed under the flag ⇒ byte-off.
			if CubeSphere.FP_STRUCT_FAR:
				_facet_ring.set_far_structures_registry_query(Callable(self, "structure_registry"))
				_facet_ring.set_far_structures_sampler(Callable(self, "structure_cell_at"))
				_facet_ring.set_far_structures_edits_rev_query(Callable(self, "edit_count"))
				_facet_ring.set_far_structures_near_query(Callable(self, "far_tree_near_presence"))
		# C1 FP_M2_SMOOTH_DEFER (docs/COSMOS-LOD-LADDER-SMOOTH-DESIGN.md §4): hand the FacetLodMesher (owned by
		# module_world) the smooth-residency query so its want loop defers coarse M2 megablocks under a resident
		# smooth tile — mirrors the block-LOD ladder's own set_smooth_query wiring (below). module_world stores it and
		# re-forwards on each pool-reset rebuild. Only wired under the flag ⇒ the Callable stays unset off (byte-identical).
		if CubeSphere.FP_M2_SMOOTH_DEFER and _module_world != null and _module_world.has_method("set_smooth_query"):
			_module_world.call("set_smooth_query", Callable(_facet_ring, "is_smooth_resident"))
		# COSMOS BLOCK-LOD P1 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4): the L1 (2-block-pitch) megablock rim ring — real
		# greedy-meshed blocky relief OVER the far skin, engaging at the near rim (~128) out to the ridge-1 band
		# (~700). Sibling of the far ring, gated on FP_BLOCK_LOD (default OFF → node never created → byte-identical).
		# Placed each frame from the far ring's own transform (one frame) + fed the same Sun; rebuilt on crossings.
		if CubeSphere.FP_BLOCK_LOD:
			_block_lod = FacetBlockLodRing.new()
			_block_lod.name = "FacetBlockLodRing"
			add_child(_block_lod)
			# TH4: hand it the TH0 job lane BEFORE setup so the ~1 s L0 bake runs on a worker (no crossing/boot stall);
			# main pays only the ArrayMesh commit, drained by the _job_lane.pump() already in _process. With FP_JOB_LANE
			# off (no lane) the ring falls back to a synchronous inline build (correct, but the P1 stall — pair the flags).
			_block_lod.set_job_lane(_job_lane)
			_block_lod.setup(TerrainConfig.active_facet())
			_block_lod.place(_facet_ring.transform)
			# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-E: wire the code-level arbitration so the L1
			# megablock ring never renders a facet the smooth tier already draws — a code invariant, never a
			# deploy-sed convention. Only wired when FP_FAR_SMOOTH is actually on (else the Callable stays unset
			# ⇒ `_smooth_owns` short-circuits false everywhere ⇒ byte-identical).
			if CubeSphere.FP_FAR_SMOOTH:
				_block_lod.set_smooth_query(Callable(_facet_ring, "is_smooth_resident"))
			# COSMOS BLOCK-LOD P2 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4/§5): the L2..L4 streamed ladder + the L5 GLOBAL
			# always-resident tier — blocky relief to the horizon with a power-of-2 fall-off. Both gated + default OFF ⇒
			# byte-identical. The ladder governs the SHARED NEVER-OOM ceiling (P1 L1 + L2..L4 + global mesh coarsened
			# finest-first) — it is registered the L1 ring + the global tier so one ledger binds them all.
			if CubeSphere.FP_BLOCK_LOD_GLOBAL:
				_block_lod_global = FacetBlockLodGlobal.new()
				_block_lod_global.name = "FacetBlockLodGlobal"
				add_child(_block_lod_global)
				_block_lod_global.set_job_lane(_job_lane)
				_block_lod_global.setup(TerrainConfig.active_facet())
				_block_lod_global.place(_facet_ring.transform)
			if CubeSphere.FP_BLOCK_LOD_RINGS:
				_block_lod_ladder = FacetBlockLodLadder.new()
				_block_lod_ladder.name = "FacetBlockLodLadder"
				add_child(_block_lod_ladder)
				_block_lod_ladder.set_job_lane(_job_lane)
				_block_lod_ladder.register_l1(_block_lod)
				if _block_lod_global != null:
					_block_lod_ladder.set_global(_block_lod_global)
				_block_lod_ladder.setup(TerrainConfig.active_facet())
				_block_lod_ladder.place(_facet_ring.transform)
				# REVISION 2 LAW R-E: same code-level arbitration for the L2..L4 ladder tiers.
				if CubeSphere.FP_FAR_SMOOTH:
					_block_lod_ladder.set_smooth_query(Callable(_facet_ring, "is_smooth_resident"))
			# COSMOS PLANET-LOD-CONFIG P0 (docs/COSMOS-PLANET-LOD-CONFIG-DESIGN.md §2): the crisp orbit megablock
			# disc — above the swap altitude it meshes the whole visible disc as an L4-nadir→L5-limb distance ladder
			# and retires the smooth §2V skin. Gated + default OFF ⇒ byte-identical (node never created). Placed each
			# frame from the far ring's transform (rides the SN3 scaled-body clamp); driven by the camera in _process.
			if CubeSphere.FP_BLOCK_LOD_ORBIT:
				_block_lod_orbit = FacetBlockLodOrbit.new()
				_block_lod_orbit.name = "FacetBlockLodOrbit"
				add_child(_block_lod_orbit)
				_block_lod_orbit.set_job_lane(_job_lane)
				_block_lod_orbit.setup(TerrainConfig.active_facet())
				_block_lod_orbit.place(_facet_ring.transform)
		# COSMOS SEAMLESS-SCALES C3: the heightfield skin tier fills the 96..256 annulus between the near
		# voxels and the far-ring backstop. Gated on FP_SKIN_TIER (default OFF → node never created →
		# byte-identical). Peer node placed like the far ring; driven from update_streaming/crossing/reanchor.
		# LIVE-LOOP NOTE: node + gates are validated headless; the live per-frame scheduling frame-math is
		# pending the AM real-GPU validation pass (the flag stays OFF until then).
		if CubeSphere.FP_SKIN_TIER:
			var afid := TerrainConfig.active_facet()
			_skin = _SkinTierCls.new()
			_skin.name = "FacetSkinTier"
			add_child(_skin)
			_skin.call("setup", afid)
		# COSMOS LOD-TEXTURE Phase 1 (docs/COSMOS-LOD-TEXTURE-DESIGN.md §6): the per-facet baked "satellite" far
		# texture. Created ONLY under FP_FACET_TEX (a RefCounted, not a scene node — pure data owned here), so with
		# the flag off nothing is instantiated and the far ring is byte-identical. Prewarm the currently-emitted
		# facet set synchronously (masked by the same ShaderPrewarm hold as the ring's initial _rebuild_full), then
		# bind the 6-layer base map into the ring's shell shader. NEVER-OOM: fixed pages (≈ 8.2 MB, total_bytes()).
		# LOW #3: the textured far ring exists only under the (unshaded) absolute shell shader, so the baker is
		# created only when BOTH flags are on — under FP_FACET_TEX alone the UV emission + tex shader are inert,
		# so a baker/texture would just waste memory. Both are in the deploy set.
		if CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE:
			_facet_tex = FacetTexBaker.new()
			_facet_tex.setup(TerrainConfig.active_facet())
			# docs/COSMOS-FARTREE-CHOP-DESIGN.md §4.3 (FP_FT_SKIN_CHOP): hand the baker the chop snapshot query —
			# the rung-3 twin of the far-trees chop wiring below. The query self-guards on the flag ⇒ byte-identical off.
			_facet_tex.set_edit_snap_query(Callable(self, "far_skin_edit_snap"))
			# COSMOS MAIN-THREAD ORCHESTRATION TH1 (FP_TEX_BAKE_WORKER): hand the baker the TH0 job lane so its
			# per-frame bake COMPUTE dispatches to the WorkerThreadPool worker (main pays only the update_layer).
			# No-op unless FP_TEX_BAKE_WORKER && the lane exists (FP_JOB_LANE) — the prewarm below stays on main.
			_facet_tex.set_job_lane(_job_lane)
			_facet_tex.prewarm(_facet_ring.visible_fids())
			_facet_ring.set_facet_tex(_facet_tex.base_texture())
			# COSMOS LOD-TEXTURE Phase 4: bind the (all-transparent-at-setup) close-up array now so the shader's
			# closeup_map is never an unbound sampler; no facet carries slot ≥ 0 until the first bake, so it is unsampled
			# until then. No-op unless FP_FACET_TEX_CLOSEUP is on (set_facet_closeup_tex is flag-guarded).
			_facet_ring.set_facet_closeup_tex(_facet_tex.closeup_texture())
			# COSMOS TEXTURED-LOD T1b (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R): bind the shared block-face detail atlas
			# (built ONCE, pure) + the baker's per-texel id map so the far terrain wears the real block faces. No-op off
			# FP_BLOCK_DETAIL (set_facet_detail is flag-guarded; the atlas/id pages are never built by the baker either).
			if CubeSphere.FP_BLOCK_DETAIL:
				_facet_ring.set_facet_detail(FacetDetailAtlas.build(), _facet_tex.id_texture())
			# COSMOS TEXTURED-LOD U1 (§2U.1): bind the (all-un-baked at setup) band id map so the shader's band_map is
			# never an unbound sampler; no facet carries a 64+ slot until the first band bake, so it is unsampled until
			# then. FP_SKIN_FLATCOLOR needs this bind too (the flat band drops FP_BLOCK_DETAIL) — so it is OUTSIDE the
			# detail gate now. No-op off FP_BAND_BLOCK_MAP (set_facet_band is _bm_on()-guarded).
			if CubeSphere.FP_BAND_BLOCK_MAP and (CubeSphere.FP_BLOCK_DETAIL or CubeSphere.FP_SKIN_FLATCOLOR):
				_facet_ring.set_facet_band(_facet_tex.band_texture())
			# docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md (task #99, G2): the whole-planet coarse height DEM —
			# a RefCounted (not a scene node — pure data, same discipline as _facet_tex above), independent of
			# FP_FACET_TEX/FP_SHELL_ABSOLUTE (it has its own governed pacer call site in update_streaming()).
			# No-op with the flag off (setup() never allocates) ⇒ byte-identical.
			if CubeSphere.FP_GLOBAL_RELIEF_DATA:
				_relief_data = GlobalReliefData.new()
				_relief_data.setup()
				# docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md (task #99, Stage 1b): push the shared instance into the
				# ring's ORBIT-VISIBLE base-grid colour bake. No-op (never called) unless FP_GLOBAL_RELIEF_DATA — the
				# ring's own FP_SKIN_RELIEF_SHADE check is the second, independent guard on the actual composite.
				_facet_ring.set_relief_data(_relief_data)
	elif FarTerrain.ENABLED and not CubeSphere.FACETED:
		_far = FarTerrain.new()
		_far.name = "FarTerrain"
		add_child(_far)
		# COSMOS: the far layer renders in the GLOBAL-index frame, offset −(i_org, 0, j_org) so its
		# tiles sample the SAME global column the near voxel field renders at each world spot (Fable
		# Stage 1). At spawn the chart is at (0,0) → ZERO; kept in lockstep on re-anchor/flip below.
		# FLAT_WORLD (no chart) leaves it at ZERO → byte-identical to the pre-COSMOS far layer.
		if _chart != null:
			_far.position = _chart.node_origin()      # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org (=−org at spawn)
			_far.set_chart(_chart)                     # COSMOS R1 (M5_REAL): the far bakes/aligns against the chart

	# BOOT-LOAD PROFILE: the far-ring setup — under FACETED this is FacetFarRing.setup()'s initial cache (the ~90s in the
	# shipped synchronous build; a bounded seed under FP_BOOT_ASYNC, the rest streamed across frames).
	_wb_mark("wb_farring")

	path_selected.emit(using_module)
	print("[WorldManager] rendering path: ",
		"godot_voxel module" if using_module else "GDScript fallback")
	_wb_mark("wb_rest")

	# COSMOS R1 DEV: hide the NEAR chunk render so the baked far layer can be inspected alone (render-only —
	# analytic physics + GroundCollider are untouched, so movement/collision are unchanged). Curved + dev only.
	if not CubeSphere.FLAT_WORLD and CubeSphere.DEV_HIDE_NEAR:
		# Module path: node visibility does NOT reach godot_voxel's RID mesh blocks, so collapse the module's
		# own streaming radius (max_view_distance) — the reliable lever — leaving only a tiny platform under
		# the player. Fallback path uses MeshInstance3D children, so plain node visibility works there.
		if _module_world != null and _module_world.has_method("set_render_hidden"):
			_module_world.call("set_render_hidden", true)
		if _streamer != null:
			_streamer.visible = false
		print("[WorldManager] DEV_HIDE_NEAR: near chunk render hidden (far layer isolated)")

## CLIMATE W1: inject the celestial clock so the weather grid can read game-time (insolation/seasons).
## main.gd calls this once after building the clock; null-safe (the grid falls back to its default dt).
func set_cosmos_clock(clock: CosmosEphemeris.CosmosClock) -> void:
	_cosmos_clock = clock

## The celestial clock (or null when no ORBITAL_SKY/climate clock was injected). Read-only accessor so the
## dev remote `set_time` cheat (player.remote_set_time, CONTROL_ENABLED-gated) can fold a time offset into
## the ONE clock the whole ephemeris/sky reads. Null off ORBITAL_SKY ⇒ the cheat is a no-op.
func cosmos_clock() -> CosmosEphemeris.CosmosClock:
	return _cosmos_clock

## COSMOS-PERF FALL-COLLAPSE FIX C (FP_SNOW_SKIP_AIRBORNE): true when the player is a HIGH FLYER (lattice altitude
## above the active-facet plane > OFFSURFACE_Y — the same cheap y-test the pool off-surface freeze uses) and the
## snowfall fixed-step should be skipped (no walkable ground snow under the camera at flight altitude). Byte-identical
## false with the flag off (never skips). Pure read of `_last_player_pos`.
func _snow_skip_airborne() -> bool:
	return snow_skip_airborne(_last_player_pos.y)

## The FIX C predicate as a PURE static (flag- and OFFSURFACE_Y-driven), split out so G-SNOW-AIRBORNE drives it
## directly with a synthetic altitude — no WorldManager instance needed. Byte-identical false with the flag off.
static func snow_skip_airborne(alt_y: float) -> bool:
	return CubeSphere.FP_SNOW_SKIP_AIRBORNE and alt_y > CubeSphere.OFFSURFACE_Y

## COSMOS-PERF UNATTENDED R3 (FP_ALT_REGIME) — true while the near-field machinery is FROZEN (the ORBITAL regime): no
## per-tick redesignation, no _manage_facet_pool churn, no main-thread snow step. The ONE cheap gate every freeze site
## reads. Byte-identical false with the flag off (the latch never leaves SURFACE, so `_alt_orbital` stays false).
func _alt_frozen() -> bool:
	return CubeSphere.FP_ALT_REGIME and _alt_orbital

## Public read of the ORBITAL regime latch (the freeze predicate) — for the verify_alt_regime altitude-sweep gate.
func alt_regime_orbital() -> bool:
	return _alt_frozen()

## Public read of the cumulative re-entry restore count (redesignations forced by crossing the gate downward) — the
## gate asserts this is exactly 1 across a fall (zero above the gate, one at re-entry). Read-only.
func alt_redesignate_count() -> int:
	return _alt_redesignate_count

# --- COSMOS-PERF UNATTENDED R5 (FP_EDIT_FID_INDEX) introspection — for verify_edit_fid_index.gd. Read-only. ---
## Edit keys the LAST `_rebuild_window_indices` iterated (the crossing's O() work): active-fid count (index on) vs
## total (off). The O(window) proof asserts this is bounded + independent of the total edit count.
func rebuild_scanned_last() -> int:
	return _rebuild_scanned
## Total `_edits` overlay size (all facets). The gate seeds ~200 k and checks rebuild_scanned_last() ≪ this.
func edit_count() -> int:
	return _edits.size()
## The per-fid index bucket for `fid` (edit_key -> true), or {} if none. The correctness gate compares its key set
## against a full `_edits` scan filtered to `fid` (the index MUST equal the full scan).
func edits_for_fid(fid: int) -> Dictionary:
	return _edits_by_fid.get(fid, {})
## All `_edits` keys (every facet) — the correctness gate's full-scan reference source.
func all_edit_keys() -> Array:
	return _edits.keys()
## The packed cell value stored at edit key `k` (0 if absent) — the gate's reference for the `_placed_top` high-water.
func all_edit_value(k: Variant) -> int:
	return int(_edits.get(k, 0))
## The rebuilt window PERF indices — the correctness gate compares these against a manual full-scan reference to
## prove the indexed rebuild produced byte-identical `_edit_columns`/`_placed_top`.
func debug_edit_columns() -> Dictionary:
	return _edit_columns
func debug_placed_top() -> Dictionary:
	return _placed_top
## Seed one overlay edit at `cell` in the CURRENT active facet's frame, skipping the render paint (headless gates
## have no module/streamer). Routes through the ONE write choke point so the R5 index is exercised exactly as a live
## snow/place write would maintain it. Test-only helper (verify_edit_fid_index.gd); no live caller.
func seed_edit_for_test(cell: Vector3i, packed: int) -> void:
	_write_cell(cell, packed, null, false)

## The player's RADIAL altitude (blocks above the planet surface) derived from a lattice position in the CURRENT active
## facet's frame — the WorldManager-side mirror of Player.radial_altitude() (lattice → world via FacetAtlas, minus the
## planet radius). This is the physically-correct "how far up am I" the sky/atmo/weather gates already use (vs the
## cheap plane-relative lattice-y the pool/snow off-surface tests use). Non-faceted / no active facet ⇒ the raw y.
func _radial_altitude_lattice(player_pos: Vector3) -> float:
	if not CubeSphere.FACETED:
		return player_pos.y
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return player_pos.y
	var w := FacetAtlas.lattice_to_world64(fid, player_pos.x, player_pos.y, player_pos.z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FacetAtlas.R_BLOCKS

## COSMOS-PERF UNATTENDED R3 — advance the altitude regime latch from the current player position (called once per
## physics tick from update_streaming, under FP_ALT_REGIME). The freeze RELEASES (and arms the ONE re-entry
## redesignation) at ATMO_TOP + ALT_REGIME_REENTRY_PREP — ABOVE the surface-physics ceiling (ATMO_TOP) — so the near
## field lands on the true sub-camera facet BEFORE floor/collision/walk ever run, never against the STALE frozen
## launch facet (the RE-ENTRY FIX: the "fall-from-orbit tunnels through the planet to the antipode" bug — surface
## physics against the wrong facet's terrain → fall-through / late pop). It ENTERS one hysteresis band higher, at
## ATMO_TOP + ALT_REGIME_REENTRY_PREP + ALT_REGIME_HYST, so a grazing pass never flaps the freeze and the high-orbit
## bulk stays frozen. On the ORBITAL→SURFACE edge it arms `_alt_reentry_pending`, which the next maybe_cross_facet
## consumes to restore the near field onto the sub-camera facet. No-op with the flag off.
func _update_alt_regime(player_pos: Vector3) -> void:
	if not CubeSphere.FP_ALT_REGIME or not CubeSphere.FACETED:
		return
	var alt := _radial_altitude_lattice(player_pos)
	if _alt_orbital:
		# Release ABOVE the surface ceiling so the near field is correct BEFORE surface physics begins AND has the
		# whole sub-ceiling descent to stream (the slow-web fall-through fix). Was ATMO_TOP − ALT_REGIME_HYST (352),
		# which sat inside the surface regime → surface queries hit the stale frozen far facet for ~32 blocks.
		if alt < CubeSphere.ATMO_TOP + CubeSphere.ALT_REGIME_REENTRY_PREP:
			_alt_orbital = false
			_alt_reentry_pending = true   # armed for the next maybe_cross_facet: ONE restore redesignation
	else:
		if alt > CubeSphere.ATMO_TOP + CubeSphere.ALT_REGIME_REENTRY_PREP + CubeSphere.ALT_REGIME_HYST:
			_alt_orbital = true           # FREEZE the near field (nothing near-field is on screen up here)

## COSMOS SEAMLESS-TRANSITION S1 (FP_APPROACH_ANCHOR, §3.1/§3.2) — the ground-anchored viewer + τ-timed release,
## driven once per streaming tick from update_streaming. `h` is the SAME analytic altitude the regime ladder uses
## (_radial_altitude_lattice → radius − R_BLOCKS; NEVER the voxel buffer — collision/floor queries are untouched).
## (a) ANCHOR: offset_y = clamp(O_base − h, −h + ANCHOR_MARGIN, O_base) pins the viewer's WORLD radial altitude to
## O_base (the sub-player ground) for every h, so the meshed plate stays inside the unchanged ellipsoid on climb.
## (b) RELEASE: the camera-to-plate distance ≈ h (plate anchored directly below); ramp view_distance down across
## [ANCHOR_REL_LO, ANCHOR_REL_HI] so the plate recedes rim-inward (every unloading block ≤ τ px). The hysteresis
## latch `_anchor_released` picks the ramp's lower knee: ANCHOR_REL_LO while resident (ascent releases at ~700),
## ANCHOR_REL_LO/ANCHOR_HYST once released (descent re-grows to full only below ~609) — no flap around the knee.
## Both writes are debounced to ≥ ANCHOR_WRITE_DEBOUNCE_MS (anti re-mesh churn; the FP-M1c staged-view precedent).
## No-op / byte-identical with the flag off, off FACETED, on the fallback path, or before the viewer attaches.
func _update_approach_anchor(player_pos: Vector3) -> void:
	if not CubeSphere.FP_APPROACH_ANCHOR or not CubeSphere.FACETED:
		return
	if not using_module or _module_world == null or not _module_world.has_method("set_approach_anchor"):
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _anchor_last_write_ms < CubeSphere.ANCHOR_WRITE_DEBOUNCE_MS:
		return                                 # debounce: at most one offset/view write per ANCHOR_WRITE_DEBOUNCE_MS
	_anchor_last_write_ms = now_ms
	_apply_approach_anchor(player_pos)

## The compute+apply core shared by the debounced driver and the verify hook (approach_anchor_step_now). Advances the
## release-latch hysteresis, computes the anchor offset + release view_distance from the analytic altitude, and pushes
## both to the single player VoxelViewer. Pure w.r.t. gameplay — it only mutates the viewer node (render/streaming).
func _apply_approach_anchor(player_pos: Vector3) -> void:
	var h := _radial_altitude_lattice(player_pos)   # the regime-ladder altitude (analytic; never the voxel buffer)
	# COSMOS SUMMIT-STREAM S1 (FP_SUMMIT_STREAM, docs/COSMOS-SUMMIT-STREAM-PRIORITY-DESIGN.md §S1): the anchor/release
	# input must be height above the LOCAL GROUND under the player, not radial altitude above the datum sphere. Shipped
	# `h` (|world| − R) drags the anchored viewer O_base BELOW the datum by the full ground relief — on a 66-block
	# summit the VoxelViewer sits ~62 blocks inside the mountain, so godot_voxel's distance-priority serves the invisible
	# interior first and the visible surface last. `ground_h` = the analytic surface's radial altitude directly below the
	# player, read through the SAME memoized column the physics already queries every tick (surface_y → effective_height;
	# zero new cost). Grounded on ANY terrain ⇒ h_eff ≈ 0 ⇒ offset ≈ O_base ⇒ the ellipsoid re-centres on the player and
	# the surface under/around them is nearest-first — identical on a summit and a plain. Airborne, h_eff is the true
	# camera-to-ground distance the S1 release law always meant, so the fly-up/de-orbit law is preserved by construction.
	# Off ⇒ h_eff == h (byte-identical inputs to both the offset and the release below).
	var h_eff := h
	if CubeSphere.FP_SUMMIT_STREAM:
		var surf_lat_y := surface_y(player_pos.x, player_pos.z)
		var ground_h := _radial_altitude_lattice(Vector3(player_pos.x, surf_lat_y, player_pos.z))
		h_eff = maxf(h - ground_h, 0.0)
	var o_base := TerrainConfig.clamped_viewer_offset_y()
	var offset_y := CubeSphere.approach_offset_y(h_eff, o_base)
	# Advance the hysteresis latch (Schmitt on the FULL-resident knee), then pick the ramp's lower knee from it.
	var d := maxf(h_eff, 0.0)                        # camera-to-plate distance ≈ altitude above the anchored ground
	if d >= CubeSphere.ANCHOR_REL_HI:
		_anchor_released = true
	elif d <= CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST:
		_anchor_released = false
	var lo := (CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST) if _anchor_released else CubeSphere.ANCHOR_REL_LO
	var full := float(TerrainConfig.near_render_radius())
	var view_f := CubeSphere.approach_view_distance(d, full, lo)
	var near_vd := int(round(view_f))
	_module_world.call("set_approach_anchor", offset_y, near_vd)
	# COSMOS SEAMLESS-TRANSITION S1↔L1 rim coupling (SEAMLESS-SCALES §4): drive the L1 megablock ring's EFFECTIVE
	# engagement rim from the SAME near view_distance just written to the viewer, so as S1 shrinks the near field below
	# the static 128 the L1 hand-off tracks it inward (near-voxels → L1, never a far-skin/L2 annulus). Only when
	# FP_BLOCK_LOD built the ring (this whole method already runs only under FP_APPROACH_ANCHOR) ⇒ the coupling is active
	# iff BOTH flags are on; with either off the ring keeps its static 128 (byte-identical). Inherits S1's debounce +
	# monotone ramp (same call site) — no re-mesh churn (the ring meshes whole facets; this is a bookkeeping value).
	if CubeSphere.FP_BLOCK_LOD and _block_lod != null:
		_block_lod.set_effective_rim(CubeSphere.block_lod_effective_rim(near_vd))

## FP_APPROACH_ANCHOR verify hook (verify_approach_anchor.gd — no live caller): run one compute+apply immediately,
## bypassing the wall-clock debounce (headless ticks are sub-ms apart). Gated exactly like the driver so an OFF build
## is a no-op. Mirrors the module's pool_ramp_tick test-hook pattern.
func approach_anchor_step_now(player_pos: Vector3) -> void:
	if not CubeSphere.FP_APPROACH_ANCHOR or not CubeSphere.FACETED:
		return
	if not using_module or _module_world == null or not _module_world.has_method("set_approach_anchor"):
		return
	_apply_approach_anchor(player_pos)

## COSMOS STREAM-SETTLE (feat/voxiverse-stream-settle) — the dev teleport / fast-travel RE-ANCHOR. A dev
## _dev_reposition sets the active facet + player pose, but the near field (the godot_voxel VoxelViewer's terrain)
## is a POOL keyed to a facet: on a jump to a FRESH FAR facet nothing re-designates the near pool onto it, so the
## meshed near bubble stays stranded on the OLD facet (the live "player in space, draws≈43, near field elsewhere"
## symptom) and never streams in at the new spot. This drives the SAME committed redesignation a seam crossing uses
## — but for a DIRECT jump (slot −1, like the R3 re-entry restore) — so the near pool + far ring + block-LOD + the
## ActiveFrame all re-derive onto the new sub-player facet NOW, then re-applies the S1 approach anchor immediately
## (bypassing the wall-clock debounce) so the viewer offset/view are correct at the new spot this frame. The
## returned reframe dict is intentionally DISCARDED — the teleport already committed the player's pose. No-op /
## byte-identical off FACETED (FLAT viewers are children of the player and already follow horizontally).
func dev_reanchor_near(player_pos: Vector3) -> void:
	if not CubeSphere.FACETED:
		return
	var to := TerrainConfig.active_facet()
	if to < 0:
		return
	# The facet the near pool CURRENTLY holds (module truth — independent of TerrainConfig timing). If it already
	# matches the target the near field is on the right facet (a same-facet teleport) and only streaming re-centres.
	if using_module and _module_world != null and _module_world.has_method("pool_active"):
		var from := int(_module_world.call("pool_active"))
		if from >= 0 and from != to:
			# Reuse the committed-crossing bookkeeping for the redesignation (pool redesignate/spawn/reset, far-ring +
			# skin + block-LOD re-place, ActiveFrame flip, gravity/collider resync). slot −1 = a direct jump (no seam).
			# np is unused by the caller path here (we discard the return), so pass the current pose.
			_commit_facet_change(from, to, [player_pos.x, player_pos.y, player_pos.z], -1)
	# Re-derive the S1 ground-anchored viewer offset + release view_distance at the NEW altitude immediately (the
	# per-tick driver is wall-clock debounced; this hook bypasses it, exactly like verify_approach_anchor).
	approach_anchor_step_now(player_pos)

## COSMOS STREAM-SETTLE: is the near field MESHED in a tight column under the player yet (the settle-release probe)?
## Routes to the module's is_area_meshed column check; false on the fallback / no-module path (settle then rides its
## hard cap instead of hanging). `player_pos` is accepted for signature symmetry — the module probes the viewer point.
func near_column_meshed(_player_pos: Vector3) -> bool:
	if not (using_module and _module_world != null and _module_world.has_method("player_column_meshed")):
		return false
	return bool(_module_world.call("player_column_meshed"))

## COSMOS STREAM-SETTLE: can the near-coverage probe actually answer here (FACETED + godot_voxel module with the
## column probe)? The dev teleport only ENGAGES the hover-until-meshed settle when this is true; on the FLAT /
## fallback path it keeps the shipped immediate ground clamp (byte-identical), so a no-module dev teleport never
## hangs on a probe that can never pass.
func near_coverage_available() -> bool:
	return CubeSphere.FACETED and using_module and _module_world != null \
		and _module_world.has_method("player_column_meshed")

## Step the dormant-by-default snowfall sim on the MAIN thread once the player position is known. It is a
## no-op with no player (headless verify drives the system directly) or while the prewarm keeps the player
## frozen (update_streaming — the only thing that sets _have_player_pos — is not called until unfrozen).
func _process(delta: float) -> void:
	# docs/COSMOS-STRUCTURES-DESIGN.md (P0, §4.2): advance the structure tracker's debounced recluster (a removal-
	# dirtied cluster re-floods once the removal burst settles). Cheap no-op when nothing is dirty; null off (byte-off).
	if _structure_tracker != null:
		_structure_tracker.tick(Time.get_ticks_msec())
	# COSMOS-PERF UNATTENDED R3: also skip the main-thread snow step while the ORBITAL near field is frozen (composes
	# with FP_SNOW_SKIP_AIRBORNE — either predicate suppresses the step; no snow accumulates visibly from orbit).
	# FP_LOAD_DEFER (docs/COSMOS-FAST-LOAD-DESIGN.md §2.3): a third suppressor — skip the ~20-25 ms/frame snow step while
	# the fresh load hasn't settled. Snow is invisible to a player staring at a loading near field, dormant-by-default,
	# and persists via _edits, so a delayed start is semantically free. `not FP_LOAD_DEFER or _load_settled` ⇒ byte-off.
	if _snowfall != null and _have_player_pos and not _snow_skip_airborne() and not _alt_frozen() \
			and (not CubeSphere.FP_LOAD_DEFER or _load_settled):
		var t_snow := Time.get_ticks_usec()   # T2f: attribute the snowfall fixed-step spike
		_snowfall.process(delta, _last_player_pos)
		_snow_us_max = maxi(_snow_us_max, Time.get_ticks_usec() - t_snow)
	# COSMOS CLIMATE W1: advance the weather grid one sweep slice (main thread). The game_time drives
	# insolation/seasons; with no clock yet (or flag off) it simply doesn't run. Timed separately so the
	# ≤0.7 ms/frame budget can be attributed (RemoteBridge take_perf_attrib).
	if _weather != null:
		var gt := _cosmos_clock.now() if _cosmos_clock != null else 0.0
		var t_w := Time.get_ticks_usec()
		if _weather_worker != null:
			# FP_WEATHER_THREAD: the sweep runs OFF the main thread. Build the static basis on the main thread
			# (sliced, exactly as the shipped path — a bounded one-time startup cost, not the per-frame hitch),
			# then hand the steady-state sweep to the worker. Once handed off the main thread only polls: a
			# swap check + an occasional pointer flip ⇒ ~0 main-thread cost (G-WTHREAD-MAINCOST).
			if not _weather.is_ready():
				_weather.build_init()
				if _weather.is_ready():
					_weather_worker.start()   # basis done → spin the thread (it blocks until the first poll)
			else:
				_weather_worker.poll(gt)
		else:
			_weather.process(delta, gt)
		_weather_us_max = maxi(_weather_us_max, Time.get_ticks_usec() - t_w)
	# COSMOS MAIN-THREAD ORCHESTRATION TH0 (FP_JOB_LANE): pump the job lane once per frame — reap finished workers,
	# pay the bounded main-thread commit (its own drain-time telemetry), refill worker slots highest-priority-first.
	# TH0 nothing is enqueued, so this is a no-op walk of empty queues; the flag-off path skips it entirely (null).
	if _job_lane != null:
		_job_lane.pump()
	# COSMOS FP-FIXED-FRAME §10 decision 2: keep the per-facet gravity volume set matching the live pool as neighbours
	# spawn/retire between crossings (a fresh neighbour has no gravity box for ≤ this throttle window → a body over it
	# falls along the active facet's up, ≤3.7° off, until synced). Cheap: _sync_gravity_areas no-ops when the set is
	# unchanged. Gated on the fixed frame → zero extra work with the flag off (byte-identical).
	if _fixed_frame_on():
		_grav_sync_accum += delta
		if _grav_sync_accum >= 0.5:
			_grav_sync_accum = 0.0
			_sync_gravity_areas()
	# FP-M2c (§6.5): tick the load controller every frame with REAL time so it adapts to live main-thread load. The
	# FacetLodMesher reads its credit for LOD apply-ms + build grants (surfaces 1-2). The pool ramp pace (surface 3)
	# and the promote gate (surface 4) are M2d — set_stream_pace stays at its 1.0 default here (byte-identical ramp).
	if _load_ctrl != null:
		var t_ctrl := Time.get_ticks_usec()   # T2f: attribute the controller tick
		_load_ctrl.tick(Time.get_ticks_msec() / 1000.0)
		_ctrl_us_max = maxi(_ctrl_us_max, Time.get_ticks_usec() - t_ctrl)
	# FP-M2d (§6.5.3 surfaces 3-4): drive the pool view-ramp PACE from the controller every frame (stream_pace() folds
	# in the vox_gen backlog gate — 0 holds neighbour growth while the pool has not drained), and, only under SUSTAINED
	# overload, apply the pause-first LOD demote relief. With FP_M2_LOD off neither is called (pace stays 1.0 — byte-identical).
	if CubeSphere.FP_M2_LOD and _load_ctrl != null and _module_world != null:
		if _module_world.has_method("set_stream_pace"):
			_module_world.call("set_stream_pace", float(_load_ctrl.stream_pace()))
		# W3: relief coarsens ONE least-wanted LOD facet per call; fire it at most once per CTRL_TICK_S (demote_pressure()
		# stays continuously true once tripped, so an unthrottled per-frame call would strip the whole field in ~1s).
		if bool(_load_ctrl.demote_pressure()) and _module_world.has_method("lod_demote_pressure"):
			var now_relief := Time.get_ticks_msec()
			if now_relief - _last_demote_relief_ms >= int(CubeSphere.CTRL_TICK_S * 1000.0):
				_last_demote_relief_ms = now_relief
				_module_world.call("lod_demote_pressure")
	# FP-M2b: the LOD covered set grows/shrinks as builds apply + facets evict (not only on a pool spawn/retire), so
	# resync the far-ring exclusion on a slow throttle. set_pool_excluded no-ops when the set is unchanged (cheap).
	# Gated on FP_M2_LOD → zero extra work with the flag off (byte-identical to FP-M1c).
	if CubeSphere.FP_M2_LOD and _facet_ring != null:
		_lod_excl_accum += delta
		if _lod_excl_accum >= 0.5:
			_lod_excl_accum = 0.0
			_facet_ring_sync_exclusion()

## FP_WEATHER_THREAD: JOIN the weather worker before the node is torn down so no thread outlives the scene
## (the SnowfallSystem/pool teardown discipline). stop() is safe if the worker was never started, and a
## no-op when the flag is off (the worker is null). Byte-identical with the flag off (the method is inert).
func _exit_tree() -> void:
	if _weather_worker != null:
		_weather_worker.stop()

func _setup_module_path() -> void:
	# module_world.gd touches godot_voxel only via ClassDB/strings and a
	# runtime-compiled generator, so loading it is safe even when the module is
	# absent (it just returns false from setup()).
	var script: Script = load("res://src/world/voxel_module/module_world.gd")
	if script == null:
		return
	var world := script.new() as Node3D
	add_child(world)
	if world.call("setup"):
		_module_world = world
		using_module = true
		_lod_ctrl_setup()
	else:
		world.queue_free()

## FP-M2c (§6.5): create the StreamLoadController, wire the LIVE measured-load source, and forward it to
## module_world (which passes it to the FacetLodMesher for surfaces 1-2 and holds it for the surface-3 ramp pace).
## No-op unless FP_M2_LOD → the controller is never created with the flag off (byte-identical to FP-M1c).
func _lod_ctrl_setup() -> void:
	if not CubeSphere.FP_M2_LOD or _module_world == null:
		return
	# preload (not the global class_name) so a core always-parsed script never depends on the stale editor class cache
	# (the codebase convention — verify_fp_m2 preloads FLM/FLB likewise). The inner LiveSource resolves off the script.
	var slc: Script = load("res://src/world/stream_load_controller.gd")
	_load_ctrl = slc.new()
	_load_ctrl.set_input_source(slc.LiveSource.new())
	if _module_world.has_method("set_load_controller"):
		_module_world.call("set_load_controller", _load_ctrl)

## FP-M2c external injection hook (the harness M2e-WIRE point): override the owned controller (e.g. a soak driver
## injecting a scripted source). Forwards to module_world so the mesher + ramp read the same instance.
func set_load_controller(c) -> void:
	_load_ctrl = c
	if _module_world != null and _module_world.has_method("set_load_controller"):
		_module_world.call("set_load_controller", c)

## FP-M2c: the current admission credit ∈ [0,1] (1.0 when no controller — the flag-off / fallback default).
func stream_load_credit() -> float:
	return float(_load_ctrl.credit()) if _load_ctrl != null else 1.0

## CROSSING-FASTGEN obs-2 fix (4) — telemetry-only accessor: the controller's setpoint/floor/overload trace so the
## remote bridge can emit "adaptive off" vs "on but genuinely over setpoint" directly. Empty when there is no controller
## (flag-off / fallback). Read-only — no frame behaviour changes. See StreamLoadController.stats().
func stream_load_stats() -> Dictionary:
	return (_load_ctrl.stats() as Dictionary) if _load_ctrl != null else {}

## MAIN-THREAD BREAKDOWN (streaming-hitch instrumentation) — godot_voxel's own per-_process timing
## breakdown, forwarded from the module path (see ModuleWorld.terrain_main_thread_stats). Empty on the
## GDScript fallback path / before setup. Telemetry-only; read-only; no frame behaviour changes.
## STREAM-SCHED T1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §7 row T1) — the generator's per-class block
## histogram, forwarded from the module path (see ModuleWorld.gen_class_stats). Empty on the GDScript
## fallback path / before setup. Telemetry-only; read-only; no frame behaviour changes.
func gen_class_stats() -> Dictionary:
	if _module_world != null and _module_world.has_method("gen_class_stats"):
		var d = _module_world.call("gen_class_stats")
		if d is Dictionary:
			return d as Dictionary
	return {}

func terrain_main_thread_stats() -> Dictionary:
	if _module_world != null and _module_world.has_method("terrain_main_thread_stats"):
		var d = _module_world.call("terrain_main_thread_stats")
		if d is Dictionary:
			return d as Dictionary
	return {}

func _setup_fallback_path() -> void:
	_streamer = ChunkStreamer.new()
	_streamer.name = "ChunkStreamer"
	add_child(_streamer)
	_streamer.setup(self)

## COSMOS FP-FIXED-FRAME (§10 decision 5): the fixed frame is active only when its flag AND both prerequisites
## are on (FACETED for a facet play frame, FP_M1_POOL for the redesignation crossing it replaces). Off ⇒ every
## fixed-frame branch below is inert and the build is byte-identical.
func _fixed_frame_on() -> bool:
	return CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL

## The FrameAdapter every physics-boundary conversion routes through (player.gd fetches it). Never null after
## _ready — a transparent identity adapter when the fixed frame is off.
func frame_adapter() -> _FrameAdapterCls:
	return _frame

## The parent node for the player, GroundCollider and loose VoxelBody debris: the ActiveFrame when the fixed frame
## is on, else this WorldManager (@ identity) exactly as today. THE single seam that makes every debris scan +
## spawn frame-correct without touching their bodies.
func _frame_host() -> Node3D:
	return _active_frame if _active_frame != null else self

## COSMOS FP-FIXED-FRAME §2.2 step 6 — the world gravity vector debris fall along, in the ABSOLUTE (scene) frame.
## −T_active.basis.y (the active facet's up) when the fixed frame is on; Vector3.DOWN (the default) otherwise. Read
## by the headless gate (must equal −FacetAtlas.facet_transform(active).basis.y after a crossing).
func gravity_vector() -> Vector3:
	return _gravity_vec

## COSMOS FP-FIXED-FRAME re-anchor helper (§3): fold the current floating-origin shift into an ABSOLUTE placement
## transform — same rotation, origin slid by −_anchor_offset. ZERO offset ⇒ returns `t` unchanged (byte-identical).
func _anchored(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis, t.origin - _anchor_offset)

## The accumulated floating-origin shift (blocks) — the amount every absolute node has been slid toward the render
## origin. `true_abs = node.global + active_anchor_offset()` is the invariant a re-anchor preserves (gate reads it).
func active_anchor_offset() -> Vector3:
	return _anchor_offset

## Phase-0 telemetry guard (§3): the running max of the player's rendered-absolute magnitude. Surfaced live by the
## remote bridge so the |player_abs| headroom (and any re-anchor need at larger R) is evidence-based, not assumed.
func player_abs_max() -> float:
	return _player_abs_max

# COSMOS FP-FIXED-FRAME §10 decision 2 — per-facet gravity box dims (blocks). Tangential half-extent (160) exceeds a
# facet's ~100-block half-width so a body anywhere over facet F is inside F's box, yet is < the ~200-block inter-facet
# centre spacing so a body at a NEIGHBOUR facet's centre is OUTSIDE this facet's box → exact per-facet up (no seam
# double-cover at facet centres; only a thin ridge band overlaps, resolved by the active facet's higher priority).
const GRAV_BOX_TANGENTIAL := 320.0
const GRAV_BOX_VERTICAL := 2048.0     # ± ~1 k blocks about the facet mean-plane — spans bedrock → tallest surface + debris arc

## COSMOS FP-FIXED-FRAME §10 decision 2 (Phase 3) — resync the per-facet directional-gravity volume set to the LIVE
## pool: one REPLACE-override Area3D per live facet (active + ≤ POOL_MAX_NEIGHBOURS neighbours → the NEVER-OOM cap),
## each oriented to T_fid so a VoxelBody over facet F falls along F's OWN absolute up (−T_F.basis.y), not a single
## global approximation. Builds newly-live facets, frees ones that left the pool, and re-stamps the active facet's box
## with the higher priority (it wins the thin ridge overlap where the player edits/breaks). No-op when off.
func _sync_gravity_areas() -> void:
	if not _fixed_frame_on():
		return
	var want: Dictionary = {}
	if _module_world != null and _module_world.has_method("pool_fids"):
		for fid in _module_world.call("pool_fids"):
			want[int(fid)] = true
	else:
		want[TerrainConfig.active_facet()] = true
	# Free gravity boxes whose facet is no longer live (bounds the set — NEVER-OOM).
	for fid in _gravity_areas.keys():
		if not want.has(fid):
			var dead: Area3D = _gravity_areas[fid]
			_gravity_areas.erase(fid)
			if is_instance_valid(dead):
				dead.queue_free()
	# Build gravity boxes for newly-live facets.
	for fid in want.keys():
		if fid >= 0 and not _gravity_areas.has(fid):
			_gravity_areas[fid] = _build_facet_gravity_area(fid)
	_stamp_active_gravity()

## Build one directional-gravity Area3D for facet `fid`: a REPLACE-override box, oriented + placed at the facet's
## absolute (re-anchored) transform with a child box shifted over the facet's own patch (centre cell), gravity along
## −T_fid.basis.y. Masks the BODY layer only, so the analytic player (CharacterBody3D ignores area gravity) is untouched.
func _build_facet_gravity_area(fid: int) -> Area3D:
	var area := Area3D.new()
	area.name = "FacetGravity_%d" % fid
	area.collision_layer = 0
	area.collision_mask = VoxelBody.LAYER_BODY
	area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.gravity_point = false
	area.gravity_direction = -FacetAtlas.facet_transform(fid).basis.y.normalized()
	area.gravity = 9.8
	area.priority = 1
	area.transform = _anchored(FacetAtlas.facet_transform(fid))
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Offset the box over the facet's PATCH: the facet-centre lattice cell (T_fid's origin is the lattice ORIGIN, far
	# from the patch via the decorrelation offset O). In the Area's local (lattice) frame +Y is the facet up.
	var centre := FacetAtlas.centre_cell(fid)
	# COSMOS-TREE-BUGS Bug 2a fix (FP_GRAV_BOX_COVER): the fixed ±160 box (sized 2026-07-15 for a ~200-block-wide
	# facet) no longer covers the facet after the 2026-07-19 R=6371 rescale grew facets to ~500-590×350-400 —
	# the outer ~60% of the domain got NO gravity Area3D (falls back to Godot's project-default global
	# (0,-9.8,0)). Size + CENTRE the box from the facet's OWN measured domain instead of the fixed half-extent
	# @ centre_cell (the domains are asymmetric about centre_cell too, so the shipped centring is also wrong).
	# `maxf` with the shipped half-extent means a genuinely tiny/degenerate domain never SHRINKS the box below
	# the old floor. Off ⇒ the shipped 320×2048×320 box @ centre_cell, byte-identical.
	if CubeSphere.FP_GRAV_BOX_COVER:
		var lo := FacetAtlas.dom_min(fid)
		var hi := FacetAtlas.dom_max(fid)
		var half_x := maxf(float(hi.x - lo.x) * 0.5 + CubeSphere.GRAV_BOX_MARGIN, GRAV_BOX_TANGENTIAL * 0.5)
		var half_z := maxf(float(hi.y - lo.y) * 0.5 + CubeSphere.GRAV_BOX_MARGIN, GRAV_BOX_TANGENTIAL * 0.5)
		box.size = Vector3(half_x * 2.0, GRAV_BOX_VERTICAL, half_z * 2.0)
		cs.position = Vector3((float(lo.x) + float(hi.x)) * 0.5, 0.0, (float(lo.y) + float(hi.y)) * 0.5)   # domain centre, not centre_cell
	else:
		box.size = Vector3(GRAV_BOX_TANGENTIAL, GRAV_BOX_VERTICAL, GRAV_BOX_TANGENTIAL)
		cs.position = Vector3(float(centre.x), 0.0, float(centre.y))
	cs.shape = box
	area.add_child(cs)
	add_child(area)
	return area

## Stamp `_gravity_vec` = the ACTIVE facet's down (for the headless gate + any single-vector consumer) and bias the
## active facet's box priority above its neighbours' so it wins the thin ridge overlap (the "clean crossing between
## volumes" — a body at the active/neighbour seam falls to the active floor the player is standing on).
func _stamp_active_gravity() -> void:
	var fid := TerrainConfig.active_facet()
	if fid >= 0:
		_gravity_vec = -FacetAtlas.facet_transform(fid).basis.y.normalized()
	for f in _gravity_areas.keys():
		var a: Area3D = _gravity_areas[f]
		if is_instance_valid(a):
			a.priority = (2 if f == fid else 1)

## The gravity DIRECTION a live per-facet volume applies for facet `fid` (−T_fid.basis.y), or Vector3.ZERO if `fid`
## has no live volume. The exact per-facet-up model the gate asserts against FacetAtlas.facet_of_dir(body position).
func gravity_direction_for_facet(fid: int) -> Vector3:
	var a: Area3D = _gravity_areas.get(fid)
	return a.gravity_direction if (a != null and is_instance_valid(a)) else Vector3.ZERO

## The bounded set of facets with a live gravity volume (== the live pool). Gate reads it to assert the NEVER-OOM cap.
func live_gravity_facets() -> Array:
	return _gravity_areas.keys()

## Called once the player exists (module path attaches its VoxelViewer here).
func on_player_ready(player: Node3D) -> void:
	# COSMOS FP-FIXED-FRAME (§2.1/§7 P1): re-home the player under the ActiveFrame so its LOCAL transform is the
	# facet-lattice pose while its GLOBAL transform (what physics + the renderer consume) comes out planet-absolute.
	# reparent() preserves the global transform, and in Phase 1 ActiveFrame is @ identity so local == global (the
	# spawn pose main.gd just set is unchanged to the bit). No-op when the fixed frame is off (player stays put).
	if _active_frame != null and player.get_parent() != _active_frame:
		# main.gd set the spawn as a LATTICE pose — its GLOBAL under the identity `main` parent (a plain Node → the
		# player's local == global there). Capture it, reparent (reparent preserves the GLOBAL pose), then RE-ASSERT it
		# as the LOCAL pose so the player rides the ActiveFrame: its global becomes T_active·lattice (Phase 2 tilted) /
		# == lattice when T_active is identity (byte-identical). Without this, reparent under the tilted frame would
		# reinterpret the lattice spawn as an absolute pose and mislocate the player by T_active.
		var lattice_pose := player.transform
		player.reparent(_active_frame)
		player.transform = lattice_pose
	# COSMOS R2.2: install the frozen epoch bake frame + push it to the C++ near mesher BEFORE the viewer
	# attaches (so the very first streamed block bakes to true geometry, not flat-window). Anchor at the
	# player's spawn — place_true(anchor)=0, so epoch coords stay smallest around the player.
	m5_real_install_epoch(player.global_position)
	if using_module and _module_world != null:
		_module_world.call("attach_viewer", player)
	# COSMOS FP-R0 SPIKE (flag-gated): render the spawn facet's edge neighbours as REAL rotated voxel terrains
	# across the seams, where today the player sees only the flat FacetFarRing quad. DEAD unless FACETED && FP_R0
	# (both const false on the shipped tree) → this call is skipped and the faceted build is byte-identical.
	if CubeSphere.FACETED and CubeSphere.FP_R0:
		_fp_r0_spike_neighbours()

## COSMOS FP-R0 SPIKE (throwaway VISUAL wiring — see docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §8). For each
## edge neighbour of the spawn (active) facet, instantiate module_world's rotated-neighbour VoxelTerrain (its own
## frozen-neighbour generator + own carve mesher, the ONE shared baked library, parented under that facet's real
## det=+1 placement) and plant a dedicated static viewer at the neighbour centre-surface so it streams+meshes its
## own band. The spiked neighbours are then excluded from the far ring so their flat quads don't z-fight the real
## voxels. No-op guarded by the caller on CubeSphere.FP_R0; only reachable in faceted mode with the module present.
func _fp_r0_spike_neighbours() -> void:
	if _module_world == null or not _module_world.has_method("spike_rotated_neighbour"):
		return
	var active := TerrainConfig.active_facet()
	if active < 0:
		return
	var excluded: Array = []
	for slot in range(4):
		var nb: int = FacetAtlas.seam_neighbour(active, slot)
		if nb < 0 or nb == active or excluded.has(nb):
			continue
		var built: Dictionary = _module_world.call("spike_rotated_neighbour", nb, 96)
		if built.is_empty():
			continue
		# Plant a static viewer at the neighbour's centre-surface WORLD point so it streams its own surface band
		# (the player's global viewer localises out of a 96-block reach of a neighbour ridge — see spike helper).
		var cc: Vector2i = FacetAtlas.centre_cell(nb)
		var g := int(TerrainConfig.facet_profile(nb, cc.x, cc.y).x)
		var w: Array = FacetAtlas.lattice_to_world64(nb, float(cc.x), float(g + 2), float(cc.y))
		_module_world.call("spike_static_viewer", Vector3(w[0], w[1], w[2]), 96)
		excluded.append(nb)
		print("[FP-R0] spiked rotated neighbour facet %d (slot %d) as REAL voxels across the seam" % [nb, slot])
	# Suppress the flat far-ring quads for the facets we now draw as real rotated voxels (no double-draw).
	if not excluded.is_empty() and _facet_ring != null:
		_facet_ring.set_excluded(excluded)
	print("[FP-R0] spike wired %d rotated neighbour terrain(s) around active facet %d" % [excluded.size(), active])

## COSMOS R2.2: freeze this epoch's shared bake frame (anchored at `anchor`), push its flat params to the
## C++ near mesher (VoxelMesherBlocky.set_cosmos_bake) so blocky meshes bake to true sphere geometry, and
## lock the far layer onto the SAME frame so near + far coincide. Re-run at each home-face flip (new epoch).
## No-op unless curved + M5_REAL + a chart exists → FLAT / R1-only paths are byte-identical.
func m5_real_install_epoch(anchor: Vector3) -> void:
	if CubeSphere.FLAT_WORLD or not CubeSphere.M5_REAL or _chart == null:
		return
	_epoch_anchor = anchor
	_epoch_frame = CosmosTruePlace.bake_frame(_chart, anchor)
	if _module_world != null and _module_world.has_method("set_cosmos_bake"):
		_module_world.call("set_cosmos_bake", CosmosTruePlace.pack_bake_params_flat(_chart, _epoch_frame))
	if _far != null and _far.has_method("lock_epoch_frame"):
		_far.lock_epoch_frame(_epoch_frame)

## Called every frame with the player's world position (fallback streaming +
## keeping the local ground collider centred on the player).
func update_streaming(player_pos: Vector3) -> void:
	if _streamer != null:
		_streamer.update_center(player_pos)
	if _ground != null:
		_ground.update(player_pos)
	# CROSSING-FASTGEN obs-2 fix (3): measure the player speed for velocity-aware predictive streaming, BEFORE the
	# _last_player_pos latch below overwrites the previous sample. Read-only w.r.t. every existing structure; wholly
	# inside its flag gate so with FP_VEL_PREDICT off it never runs and _player_speed stays 0 (byte-identical). A
	# per-update speed above VEL_PREDICT_SPEED_CLAMP is a crossing/flip position discontinuity (a relocation, not
	# motion) → rejected; otherwise EMA-smoothed so a single frame never swings the promote/commit lead.
	if CubeSphere.FP_VEL_PREDICT:
		var now_usec := Time.get_ticks_usec()
		if _have_player_pos and _last_stream_usec >= 0:
			var dt := float(now_usec - _last_stream_usec) / 1.0e6
			if dt > 0.0:
				var sp := player_pos.distance_to(_last_player_pos) / dt
				if sp < CubeSphere.VEL_PREDICT_SPEED_CLAMP:
					_player_speed = lerpf(_player_speed, sp, 0.3)
		_last_stream_usec = now_usec
	# FP_ENV_FALL_HOLD: estimate the DOWNWARD lattice speed (blocks/s, EMA) and hand it to the far ring so it pauses
	# env-warm during a fast plunge (the env-build worker + whole-shell re-emit alloc firehose stalls the shared WASM
	# allocator ⇒ physics tick). Position-based (works even under the rails coast that zeroes velocity); a per-update
	# speed above the crossing/flip clamp is a relocation, not motion, and is rejected. Off ⇒ never called (byte-identical).
	# FP_LAND_RAMP_HOLD shares the same vy signal to shrink the near VOXEL view during the plunge. One estimate,
	# forwarded to both the far ring (env-warm pause) and the module (near-view clamp). Off both ⇒ never runs.
	if CubeSphere.FP_ENV_FALL_HOLD or CubeSphere.FP_LAND_RAMP_HOLD:
		var nowu := Time.get_ticks_usec()
		if _have_player_pos and _fall_last_usec >= 0:
			var dtf := float(nowu - _fall_last_usec) / 1.0e6
			if dtf > 0.0:
				var spd := player_pos.distance_to(_last_player_pos) / dtf
				if spd < CubeSphere.VEL_PREDICT_SPEED_CLAMP:
					_fall_vy_ema = lerpf(_fall_vy_ema, (player_pos.y - _last_player_pos.y) / dtf, 0.3)
		_fall_last_usec = nowu
		var hold := _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY
		if CubeSphere.FP_ENV_FALL_HOLD and _facet_ring != null and _facet_ring.has_method("set_fall_hold"):
			_facet_ring.set_fall_hold(hold)   # the FACETED far ring (FacetFarRing) — NOT _far (FarTerrain, null in faceted mode)
		if CubeSphere.FP_LAND_RAMP_HOLD and using_module and _module_world != null and _module_world.has_method("set_fall_hold"):
			_module_world.set_fall_hold(hold)
	# Latch the latest player position so _process can step the snowfall sim on the main thread. This is
	# also the gate that keeps the sim inert during the frozen prewarm (this is not called while frozen).
	_last_player_pos = player_pos
	_have_player_pos = true
	# FP_STREAM_TICK_ONCE (docs/COSMOS-MOTION-PHYS-DESIGN.md §4, #129 motion): the render-facing orchestration TAIL below
	# (_update_alt_regime → anchor → tex baker → DEM → pool → far ring → flip-settle) is identical work on both physics
	# steps of a slow 2-step frame — running it twice doubles its cost on exactly the already-slow frames AND corrupts the
	# _bg/_g2 headroom governors with a ~0ms inter-call delta on the 2nd catch-up step. Both catch-up steps share one
	# Engine.get_process_frames() (it increments AFTER the physics loop), so this runs the tail exactly once per RENDER
	# frame. The SAFETY HEAD above (streamer, GroundCollider update, pos latch) already ran per-tick → zero fall-through
	# risk (the tail writes no collision state). Off ⇒ no early return ⇒ byte-identical.
	if CubeSphere.FP_STREAM_TICK_ONCE:
		var _pf := Engine.get_process_frames()
		if _pf == _stream_tail_frame:
			return
		_stream_tail_frame = _pf
	_dbg_tail_runs += 1                     # FP_STREAM_TICK_ONCE gate read-back: tail executions (advances once/frame under the flag)
	# COSMOS-PERF UNATTENDED R3 (FP_ALT_REGIME): advance the altitude regime latch FIRST (before the pool-manage /
	# maybe_cross_facet freeze sites read it). Above the ATMO_TOP gate this flips `_alt_orbital` true (freeze the near
	# field); on descent back through it, arms the one-shot re-entry restore. No-op / byte-identical with the flag off.
	_update_alt_regime(player_pos)
	# COSMOS SEAMLESS-TRANSITION S1 (FP_APPROACH_ANCHOR): keep the meshed near plate anchored to the sub-player ground
	# during a climb and release it rim-inward only once its blocks are sub-τ on screen. Debounced viewer offset +
	# view_distance writes; no-op / byte-identical with the flag off. Runs after the alt regime so the freezes above
	# ATMO_TOP stay authoritative (the released plate is empty up there anyway).
	_update_approach_anchor(player_pos)
	# COSMOS SEAMLESS-SCALES C3: schedule the skin tiles around the player (nearest-first, evict-farthest,
	# 8 MB-capped). player_pos is in the active facet lattice (the frame the pool works in). Candidate
	# facets = active + live-pool neighbours. No-op unless FP_SKIN_TIER created the node.
	# COSMOS SEAMLESS-SCALES C3 / TEXTURED-LOD U2: the near-coverage Callable — is a fid-lattice AABB fully meshed in the
	# near voxel field? Routed to module_world.skin_near_meshed (godot_voxel is_area_meshed); an invalid Callable on the
	# fallback / no-module path leaves BOTH consumers (the skin's covered-tile skip AND the far-ring covered-cell cull)
	# inert → byte-identical. Computed once here and shared by the skin and the far ring.
	var cover_query := Callable()
	if using_module and _module_world != null and _module_world.has_method("skin_near_meshed"):
		cover_query = Callable(_module_world, "skin_near_meshed")
	if _skin != null:
		# hand the skin the coverage query so it can drop tiles wholly behind confirmed-meshed near voxels (fill overdraw).
		_skin.call("update", TerrainConfig.active_facet(), player_pos, _skin_candidate_fids(), cover_query)
	# COSMOS TEXTURED-LOD U2 (FP_FARRING_CULL_COVERED): hand the far ring the SAME coverage query so it stops emitting
	# backstop cells the near field fully covers. No-op / inert unless the flag is on and the callable is valid.
	if _facet_ring != null and _facet_ring.has_method("set_cover_query"):
		_facet_ring.set_cover_query(cover_query)
	# COSMOS-FAR-NEAR-GRASSBASE §2.2 (FP_APPLIED_PROBE_SLAB): hand the far ring the bounds-safe W1 seam-strip probe
	# (module_world.pool_seam_meshed_weld) so the applied-cover box can prove its cross-border remainder on pool
	# neighbours (the flank is full-res since FP_NB_FULLRES). Invalid on the fallback / no-module path ⇒ the remainder
	# is unprovable and the box that overflows the active domain returns false — inert / byte-identical off the flag.
	if _facet_ring != null and _facet_ring.has_method("set_seam_cover_query"):
		var seam_query := Callable()
		if using_module and _module_world != null and _module_world.has_method("pool_seam_meshed_weld"):
			seam_query = Callable(_module_world, "pool_seam_meshed_weld")
		_facet_ring.set_seam_cover_query(seam_query)
	# COSMOS-FAR-NEAR-MESA §3.1 (FP_APPLIED_VIEW_BAND): hand the far ring the loadable-row-band query
	# (module_world.meshed_band_y) so the applied-cover probe demands only the vertical band the engine can actually
	# stream around the viewer's row (fixing the mesa c=0 dead-latch). Invalid on the fallback / no-module path ⇒ the
	# far ring's band clamp is skipped ⇒ inert / byte-identical off the flag (the shipped #113 probe).
	if _facet_ring != null and _facet_ring.has_method("set_band_query"):
		var band_query := Callable()
		if using_module and _module_world != null and _module_world.has_method("meshed_band_y"):
			band_query = Callable(_module_world, "meshed_band_y")
		_facet_ring.set_band_query(band_query)
	# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): feed the frozen player-column snapshot (ABSOLUTE
	# world coords, the far ring's own frame) so the S2 near-collar disc is centred on the ACTUAL player, not the
	# active facet centre. `player_pos` is in the active facet's LATTICE frame (same convention `_radial_altitude_
	# lattice` already converts) — mirror that conversion here. No-op / byte-identical unless FP_SMOOTH_RIM.
	# COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §4: FP_FARRING_UNCOVERED_TRUE's per-vertex un-sink coverage law needs this
	# SAME ABSOLUTE column too (it is exactly the S2 rim disc's own centre) — pushed unconditionally alongside
	# FP_SMOOTH_RIM rather than adding a second plumbing path. Off (both flags) ⇒ byte-identical (never called).
	if (CubeSphere.FP_SMOOTH_RIM or CubeSphere.FP_FARRING_UNCOVERED_TRUE) and _facet_ring != null and _facet_ring.has_method("set_player_column"):
		var _rim_afid := TerrainConfig.active_facet()
		if _rim_afid >= 0:
			var _rim_w := FacetAtlas.lattice_to_world64(_rim_afid, player_pos.x, player_pos.y, player_pos.z)
			_facet_ring.set_player_column(Vector3(_rim_w[0], _rim_w[1], _rim_w[2]))
	# COSMOS BLOCK-LOD P1: keep the L1 rim ring in the far ring's frame (its mesh is absolute planet coords, placed by
	# the SAME node transform so L1 and the far skin overlap exactly). No-op / byte-identical unless FP_BLOCK_LOD.
	if _block_lod != null and _facet_ring != null:
		_block_lod.place(_facet_ring.transform)
	# COSMOS BLOCK-LOD P2: keep the L2..L4 ladder + the L5 global tier in the SAME far-ring frame (absolute meshes).
	if _block_lod_ladder != null and _facet_ring != null:
		_block_lod_ladder.place(_facet_ring.transform)
	if _block_lod_global != null and _facet_ring != null:
		_block_lod_global.place(_facet_ring.transform)
	# COSMOS PLANET-LOD-CONFIG P0: keep the orbit megablock disc in the SAME far-ring frame (rides the SN3 clamp).
	if _block_lod_orbit != null and _facet_ring != null:
		_block_lod_orbit.place(_facet_ring.transform)
	# COSMOS LOD-TEXTURE Phase 2+4 (docs/COSMOS-LOD-TEXTURE-DESIGN.md §6): drive the far-texture baker under the strict
	# per-frame budget — progressive BASE coverage beyond the spawn hemisphere (nearest the emit axis first) + the
	# CLOSE-UP tier promotion/bake when off-surface. All bake work is budget-sliced on the main thread (never a stall,
	# see THE HARD PERF CONSTRAINT); when the close-up slot map changes (epoch bump) push it + the reverse-map to the
	# ring (which re-emits so UV2.y carries the new slots) and bind the close-up texture the first time it exists. No-op
	# unless FP_FACET_TEX && FP_SHELL_ABSOLUTE created the baker (byte-identical off).
	if _facet_tex != null and _facet_ring != null:
		var eaxis := _facet_ring.shell_emit_axis()
		var offs: bool = _facet_ring.shell_offsurface()
		# COSMOS TEXTURED-LOD V4 (§2V.2, FP_SKIN_SSE): the camera's scale-correct distance from the body centre so the baker's
		# screen-space MONOTONE promotion law can size each facet's on-screen blocks (no regime evict-all on descent). 0 until
		# the camera-set driver has armed ⇒ the baker's SSE law falls back to the shipped regime path (byte-identical off).
		var cam_dist: float = _facet_ring.shell_cam_dist() if _facet_ring.has_method("shell_cam_dist") else -1.0
		# COSMOS TEXTURED-LOD U1 (§2U.1): pass the active facet so the baker drives the near-far BAND (residency = active ∪
		# ring-1) alongside the base/close-up tiers. -1 (no active facet) ⇒ band idle; band code is inert off the flag.
		# COSMOS-BACKGROUND-PREBAKE (FP_BG_PREBAKE): the baker's governor input, in ms — a REAL measured wall-clock
		# delta between successive update_streaming calls (this function has no `delta` parameter of its own to
		# thread through, and this call site is reached from several callers/gates), computed the SAME way
		# StreamLoadController.LiveSource already does (never Performance.TIME_PROCESS, invalid on threaded web —
		# see that class's own doc comment). Only ever consulted under the flag; harmless to always compute/pass.
		var _bg_now_usec := Time.get_ticks_usec()
		var _bg_frame_ms := 0.0
		if _bg_last_frame_usec > 0:
			_bg_frame_ms = minf(float(_bg_now_usec - _bg_last_frame_usec) / 1000.0, CubeSphere.CTRL_FRAME_SAMPLE_CLAMP_MS)
		_bg_last_frame_usec = _bg_now_usec
		_facet_tex.update(eaxis, offs, CubeSphere.FACET_TEX_BAKE_BUDGET_MS, TerrainConfig.active_facet(), cam_dist, _bg_frame_ms)
		if CubeSphere.FP_PLANET_MAP:
			_facet_ring.set_fine_map(_facet_tex.fine_texture())   # bind the whole-planet fine tier (survives re-emit)
		if _facet_tex.slots_epoch() != _tex_slots_epoch:
			_tex_slots_epoch = _facet_tex.slots_epoch()
			if _facet_tex.closeup_texture() != null:
				_facet_ring.set_facet_closeup_tex(_facet_tex.closeup_texture())
			_facet_ring.set_closeup_slots(_facet_tex.closeup_slots(), _facet_tex.closeup_facet_map())
		# COSMOS TEXTURED-LOD U1: push the band slot map + reverse-maps when the baker's band epoch bumps (a facet baked
		# resident or evicted on a crossing) so UV2.y carries the new 64+ slots and the shader's band_facet/band_n update.
		if _facet_tex.band_epoch() != _tex_band_epoch:
			_tex_band_epoch = _facet_tex.band_epoch()
			_facet_ring.set_band_slots(_facet_tex.band_slots(), _facet_tex.band_facet_map(), _facet_tex.band_n_map())
	# docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md (task #99, G2): the SAME governed-pacer discipline as the
	# texture prebake above, but its OWN frame-time measurement (independent of _facet_tex's existence -- G2
	# must pace even when FP_FACET_TEX/FP_SHELL_ABSOLUTE are off). At most one facet bakes per call, nearest
	# the view axis first, only when the last frame had headroom; step() self-guards on the flag => off is a
	# single cheap null-check, byte-identical.
	# FP_LOAD_DEFER (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 1 — the fresh-load pile-up fix): advance the ONE settle latch
	# (flipped once off the near-view mesh probe or a wall-clock backstop; boot-once), then per-frame forward the
	# controller credit so smooth-v2's first post-settle commit can wait for the near field. Both no-op off the flag.
	_load_defer_tick(player_pos)
	if CubeSphere.FP_LOAD_DEFER and _facet_ring != null and _facet_ring.has_method("set_stream_credit_ok"):
		_facet_ring.set_stream_credit_ok(stream_load_credit() > 0.0)
	if _relief_data != null and _facet_ring != null:
		# FP_DEM_DEFER (docs/COSMOS-STREAM-PARALLEL-DESIGN.md Phase A — the fresh-reload fix): defer the whole-planet
		# DEM bake until the near view has MESHED. During the load window the DEM's only on-surface consumer (the
		# far-ring shade multiply) self-degrades to 1.0 for unbaked facets, so baking it early buys zero visible value
		# for its 20-60 ms/frame cost. The latch flips ONCE (short-circuit ⇒ `initial_view_meshed` is never even
		# queried after settle, or at all with the flag off ⇒ byte-identical).
		if CubeSphere.FP_DEM_DEFER and not _relief_settled and initial_view_meshed(player_pos):
			_relief_settled = true
			_relief_data.mark_settled()
		var _g2_now_usec := Time.get_ticks_usec()
		var _g2_frame_ms := 0.0
		if _g2_last_frame_usec > 0:
			_g2_frame_ms = minf(float(_g2_now_usec - _g2_last_frame_usec) / 1000.0, CubeSphere.CTRL_FRAME_SAMPLE_CLAMP_MS)
		_g2_last_frame_usec = _g2_now_usec
		# FP_RELIEF_REEMIT (task #99 follow-up): step() returns the fid it just baked (or -1) — forward it so the
		# ring can catch up any ALREADY-cached facet whose shade multiply ran before its DEM was ready. The ring's
		# own relief_baked() no-ops under the flag/off-cache, so this is a single cheap call either way.
		# FP_DEM_DEFER: pass off-surface state — on-surface the deferred pacer serves only the demand want-list, off-
		# surface it sweeps the rest of the planet (the near field is frozen, so there is headroom). Ignored off the flag.
		var _g2_baked_fid := _relief_data.step(_facet_ring.shell_emit_axis(), _g2_frame_ms, _facet_ring.shell_offsurface())
		_facet_ring.relief_baked(_g2_baked_fid)
	# FP-M1c (§4.3): drive the neighbour pool — spawn a facet when the player's own-side ridge distance drops
	# below D_WARM, retire it past D_RETIRE (+ MIN_LIVE_S), ≤1 op/s, hard cap 1+4. Dormant unless FP_M1_POOL.
	# COSMOS-PERF UNATTENDED R3: suspend the whole neighbour-pool manager (spawn/retire/imminent-select/ring-resync
	# churn) while the ORBITAL near field is frozen — none of it is visible at altitude, and the pool targets are held
	# until re-entry. `not _alt_frozen()` is byte-identical true with FP_ALT_REGIME off.
	if CubeSphere.FACETED and CubeSphere.FP_M1_POOL and _module_world != null and not _alt_frozen():
		_manage_facet_pool(player_pos)
	if CubeSphere.M5C_CORNER:
		m5c_glue_bodies()                 # M5c §6: keep awake debris/projectiles out of the wedge each frame
	if _far != null:
		_far.update_center(player_pos)
	# COSMOS M4 (§5.1/§5.4): while a flip's near field restreams, poll the module's view-distance ramp;
	# once it finishes the near data blocks are loaded, so re-mirror player edits into the fresh render
	# (they were dropped by the pure-worldgen restream) and end the far handoff turbo. One-shot per flip.
	if _flip_settling:
		if _module_world == null or not _module_world.has_method("ramp_done") \
				or bool(_module_world.call("ramp_done")):
			_remirror_module_edits(player_pos)     # §5.4 — BEFORE release_cover so edits are up before the cover vanishes
			if _far != null:
				_far.end_handoff()
			# COSMOS M4 Stage 2 (§5.1): release the frozen near cover — it retires once the fresh field meshes
			# under the player. Module-guarded no-op on the fallback path / with the cover flag off.
			if _module_world != null and _module_world.has_method("release_cover"):
				_module_world.call("release_cover")
			_flip_settling = false

## Has the near terrain view around `center` finished MESHING (so it renders — and its GL pipeline
## compiles — behind the load overlay)? ShaderPrewarm PHASE 2 polls this to decide when to lift the
## overlay. On the MODULE path it asks godot_voxel (is_area_meshed) over a near box; on the FALLBACK
## path it returns true immediately (the fallback chunk format is already warmed by the prewarm grid,
## so no extra hold is needed). Half-extents cover the near, always-first-to-mesh view.
func initial_view_meshed(center: Vector3) -> bool:
	if using_module and _module_world != null and _module_world.has_method("area_meshed"):
		# FP_LOAD_RAMP (perf/voxiverse-load-profile): with the initial view ramping in, hold the splash until a
		# MODEST surround is meshed rather than a bare 40-block bubble — so "playable" means actually-surrounded.
		# Round 4: 64³ (not 96³) — the 96³ box could not mesh inside the cap on web (the hold always hit the cap),
		# so reveal a little earlier and let the ring keep filling; the ShaderPrewarm [floor, cap] window still bounds
		# the wait (never hangs). Off ⇒ the shipped 40³ box (byte-identical).
		var half := Vector3(64.0, 32.0, 64.0) if CubeSphere.FP_LOAD_RAMP else Vector3(40.0, 32.0, 40.0)
		return bool(_module_world.call("area_meshed", center, half))
	return true                                     # fallback path / no module → no terrain-format hold

## FP_LOAD_DEFER (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 1): advance the ONE fresh-load settle latch. Flips `_load_settled`
## exactly once — when the near view has meshed (`initial_view_meshed`) OR the `LOAD_DEFER_FAILSAFE_MS` wall-clock cap
## trips (so a view that never meshes, e.g. a fallback-path quirk, cannot defer the far field forever) — and broadcasts
## the flip: the far ring (set_load_settled → smooth-v2 unfreeze + env load-hold release), and GlobalReliefData
## (mark_settled — the DEM defer latch settles off the SAME event; harmless when FP_DEM_DEFER is off, its step() ignores
## `_settled`). Boot-once, NO re-arm on crossings; short-circuit ⇒ the probe is never queried after settle, or at all
## with the flag off (byte-identical: `_load_settled` stays false forever and gates nothing). Returns the flip frame.
## Factored out of update_streaming so verify_fast_load.gd can drive it with a controllable `initial_view_meshed`.
## `failsafe_ms` overrides the wall-clock cap so the gate can exercise the failsafe branch without a 45 s clock wait
## (the codebase's gate-override convention). The one real caller (update_streaming) passes no override ⇒ the const.
func _load_defer_tick(center: Vector3, failsafe_ms := CubeSphere.LOAD_DEFER_FAILSAFE_MS) -> bool:
	if not CubeSphere.FP_LOAD_DEFER or _load_settled:
		return false
	if _load_defer_start_ms < 0:
		_load_defer_start_ms = Time.get_ticks_msec()
	if not (initial_view_meshed(center) or (Time.get_ticks_msec() - _load_defer_start_ms >= failsafe_ms)):
		return false
	_load_settled = true
	if _facet_ring != null and _facet_ring.has_method("set_load_settled"):
		_facet_ring.set_load_settled(true)
	if _relief_data != null:
		_relief_settled = true                          # the DEM defer latch reads the same settle event
		_relief_data.mark_settled()
	return true

## BOOT-LOAD PROFILE (perf/voxiverse-load-profile): read-only "is this arbitrary box meshed?" accessor used by
## main.gd's post-splash "world_settled" timer to measure how long the bulk near view (much larger than the tiny
## 40-box the ShaderPrewarm hold waits on) takes to stream in after the splash lifts. Same is_area_meshed query as
## initial_view_meshed, just with a caller-chosen half-extent. Telemetry-only; no gameplay read path; fallback/no
## module → true (nothing to wait on). Never called per-frame in a hot loop (main throttles it to ~2 Hz).
func view_meshed(center: Vector3, half: Vector3) -> bool:
	if using_module and _module_world != null and _module_world.has_method("area_meshed"):
		return bool(_module_world.call("area_meshed", center, half))
	return true

## FP_BOOT_ASYNC (round 4): let the deferred far-ring background warm proceed — called by main.gd at essential-ready so
## the warm runs WHILE the player plays instead of starving the shader-prewarm compile frames. No-op off the flag / no
## ring. Also kicks the deferred manifest bake (FP_MANIFEST_SLICE) so the cold-biome models bake off the boot path.
func begin_deferred_boot_work() -> void:
	if _facet_ring != null and _facet_ring.has_method("open_boot_gate"):
		_facet_ring.open_boot_gate()
	if _module_world != null and _module_world.has_method("begin_deferred_manifest_bake"):
		_module_world.call("begin_deferred_manifest_bake")

# --- terrain editing (block breaking + placing) --------------------------------

## THE composed cell query (VOXEL-DATA-STRUCTURE §7.1): edit overlay first, else
## generated terrain+trees. Returns the full PACKED cell value (material |
## modifier<<16 | state<<32); material/modifier/state are bit-projections of this
## one int, so they cannot desync. There is no second lookup that could disagree.
func cell_value_at(cell: Vector3i) -> int:
	var e: int = _edits.get(_edit_key(cell), -1)
	if e >= 0:
		return _overlay_window_modifier(cell, e)    # overlay: de-canon the directional modifier into the window frame (§6.4)
	# COSMOS-MOTION-PHYS §6.3 (FP_MOVE_PROBE_CACHE): the overlay get above stays LIVE on every query, so an edited cell
	# can never be served from the cache — this cache wraps only the generated branch (choice B, clip-through impossible
	# by construction). Main-thread only (the fallback mesher + SnowfallSystem call this off-main → they bypass, no
	# locks). Per-physics-tick transient epoch: a frame advance self-clears (the choke points also clear wholesale).
	if CubeSphere.FP_MOVE_PROBE_CACHE and TerrainConfig._on_main_thread():
		var tick := Engine.get_physics_frames()
		if tick != _gen_cache_tick:
			_gen_cache.clear()
			_gen_cache_tick = tick
		_gen_cache_cva += 1
		var cached: int = _gen_cache.get(cell, -1)
		if cached >= 0:
			_gen_cache_hit += 1
			return cached
		var gv := _cell_value_generated(cell)
		if _gen_cache.size() < CubeSphere.MOVE_PROBE_CACHE_CAP:
			_gen_cache[cell] = gv
		return gv
	return _cell_value_generated(cell)

## COSMOS-MOTION-PHYS §6.3: the GENERATED half of cell_value_at (the branch AFTER the edit-overlay miss). Extracted
## verbatim so FP_MOVE_PROBE_CACHE can memoize its return within a physics tick — a pure function of the cell whose only
## implicit parameters (active_facet, datum, chart anchor, window indices) change solely at the choke points that clear
## the cache. Called directly (cache-bypassed) off the main thread and with the flag off → byte-identical to the shipped
## inline branch.
func _cell_value_generated(cell: Vector3i) -> int:
	if _chart == null:
		var vf := TerrainConfig.generated_cell(cell.x, cell.y, cell.z)
		# COSMOS FACETED §3.5.4/§5.3: the junction authority is the analytic window exit — it MASKS cells
		# wholly beyond the active facet's ridges to AIR (the domain mask) and turns straddling cells into
		# kind-2 junction partials. _occ_span composes through ShapeCodec.span (junction-aware), so player
		# physics + the fallback mesher follow automatically. Interior cells + non-faceted mode: unchanged.
		if CubeSphere.FACETED:
			return FacetAtlas.junction_modify(TerrainConfig.active_facet(), cell, vf)
		return vf
	# COSMOS M2 (§3.1/§8.2): fold the window cell to its GLOBAL cell FIRST, then generate. Worldgen
	# is thereby a pure function of the global cell — window-INDEPENDENT — so it is byte-identical
	# no matter where the chart is anchored (the determinism the far-from-spawn streaming needs).
	var g := _chart.to_global(cell)
	var v := TerrainConfig.generated_cell_global(int(g["face"]), int(g["i"]), int(g["j"]), int(g["r"]))
	# COSMOS-FRAME-ORIENTATION §6: generated_cell_global is CANONICAL (true-face); rotate its directional
	# modifier into the window render frame HERE (the WM analytic boundary — the window cell is in hand so J
	# is derivable via the chart; the folded-true-cell inside TerrainConfig cannot derive it). No-op for a
	# full cube / identity orientation → byte-identical. Pairs with the overlay de-canon above.
	var m := CellCodec.modifier(v)
	if m == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(m, TerrainConfig.analytic_jinv_d4(p.x, p.y)))

## COSMOS-FRAME-ORIENTATION §6.4: the overlay stores a placed DIRECTIONAL modifier in its CANONICAL
## (true-face) frame so it keeps its physical direction across a future home-face flip. These two helpers
## convert between the stored canonical frame and the CURRENT window render frame (jinv on read, J = −jinv
## on write). BOTH are a no-op for a full cube (modifier 0 — everything the hotbar places today), no chart,
## or identity orientation, so current gameplay + verify_feature's break/place loop stay byte-identical.
func _overlay_window_modifier(cell: Vector3i, v: int) -> int:
	if _chart == null or v <= 0 or CellCodec.modifier(v) == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	var jinv := TerrainConfig.analytic_jinv_d4(p.x, p.y)
	if jinv == 0:
		return v
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(CellCodec.modifier(v), jinv))

func _overlay_canon_modifier(cell: Vector3i, v: int) -> int:
	if _chart == null or v <= 0 or CellCodec.modifier(v) == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	var jinv := TerrainConfig.analytic_jinv_d4(p.x, p.y)
	if jinv == 0:
		return v
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(CellCodec.modifier(v), (4 - jinv) % 4))

## COSMOS M2 (§1.3) / FP-M1a (§6.2): THE overlay key for a window cell. Three regimes:
##   • curved (chart installed) → the 43-bit GLOBAL edit key (CubeSphere), so an edit survives origin
##     re-anchors and home-face flips (its key is its global identity, not its window position);
##   • FACETED → the 59-bit (fid, cell) GLOBAL key (FacetAtlas), so an edit is bound to its facet+cell
##     forever and cannot be re-interpreted in the neighbour lattice after a crossing/re-designation;
##   • FLAT_WORLD / no chart → the Vector3i window cell itself (byte-identical to the pre-M2 store).
## Returned as a Variant because Dictionary keys are the Vector3i or the int transparently.
func _edit_key(cell: Vector3i) -> Variant:
	if _chart != null:
		return _chart.to_global_key(cell)
	if CubeSphere.FACETED:
		return FacetAtlas.edit_key(TerrainConfig.active_facet(), cell)
	return cell

## FP-M1a (§6.2): the active-facet edit overlay projected back to Vector3i lattice cells — the view the
## Vector3i-keyed consumers (fallback mesher, structural collapse solver, region save) expect. Under
## FACETED the stored keys are (fid, cell) globals, so filter to the CURRENT active facet and unpack;
## since the active facet lattice IS the world/window lattice (no chart), the unpacked cell is the
## window cell directly. FLAT / no chart returns the live `_edits` by reference (byte-identical, zero
## copy). Curved uses the dedicated window/region unfolds (placed_cells_window / save_region) instead.
func _overlay_v3i() -> Dictionary:
	if CubeSphere.FACETED and _chart == null:
		# COSMOS-PERF UNATTENDED R5: hand the per-fid index's active-facet keys so the projection is O(active-fid),
		# not a full-dict scan. Off ⇒ the shipped full-scan-and-filter (byte-identical result set).
		if CubeSphere.FP_EDIT_FID_INDEX:
			return _translate_active(_edits, _edits_by_fid.get(TerrainConfig.active_facet(), {}).keys())
		return _translate_active(_edits)
	return _edits

## FP-M1a: the active-facet METADATA overlay as Vector3i cell → document (the region-save companion of
## `_overlay_v3i`). FLAT returns the live `_meta` by reference (byte-identical).
func _meta_v3i() -> Dictionary:
	if CubeSphere.FACETED and _chart == null:
		return _translate_active(_meta)
	return _meta

## The (fid, cell)→Vector3i projection of a key-global dict (`_edits` or `_meta`) filtered to the active
## facet. Only ever called under FACETED (the caller gates), where `_chart` is null and the unpacked
## cell equals the window cell.
func _translate_active(src: Dictionary, keys: Variant = null) -> Dictionary:
	var out := {}
	var active := TerrainConfig.active_facet()
	# R5: when `keys` is supplied (the per-fid index's active bucket) every key already belongs to `active`, so the
	# fid filter is skipped — O(active-fid). `keys == null` ⇒ the shipped full-dict scan + filter (byte-identical).
	var ks: Array = (keys as Array) if keys != null else src.keys()
	for k in ks:
		if keys == null and FacetAtlas.edit_key_fid(k) != active:
			continue
		var u := FacetAtlas.edit_key_unpack(k)
		out[u[1]] = src[k]
	return out

## Material id at `cell` — the material projection of the composed query. UNCHANGED
## contract: every existing call site (floor, blocked, DDA, collider, collapse,
## both meshers, catalog/sim checks) sees the exact same 0..COUNT-1 id it always
## did, because a bare id is a canonical packed value. THE cell query for gameplay.
func block_id_at(cell: Vector3i) -> int:
	return CellCodec.mat(cell_value_at(cell))

## COSMOS-AGENT-CONTROL §5.3 (FP_AGENT_QUERY) — batched block_id_at over a box, THE agent neighbourhood query.
## Composes the ONE authoritative cell query (edit-overlay-else-generated), so the returned grid matches
## physics / render / DDA exactly (CLAUDE.md rule 1 — never a parallel "what's solid"). TIME-SLICED: fills at
## most `budget` cells per call, carrying the cursor in `state` (§5.4), so a max 31³ box never hitches a frame.
## NEVER-OOM: the caller (agent), relay validateStep, and rover _validate_cmd all cap; this asserts once more
## (an over-cap box completes empty). `state` = {"ids": PackedByteArray, "i": int}. Layout is x-fastest, then z,
## then y — i = (dy*dimz + dz)*dimx + dx — matching the header `order`. Returns true when the box is complete.
func block_box_slice(center: Vector3i, half: Vector3i, state: Dictionary, budget: int) -> bool:
	var hx := clampi(half.x, 0, CubeSphere.QUERY_HALF_MAX)
	var hy := clampi(half.y, 0, CubeSphere.QUERY_HALF_MAX)
	var hz := clampi(half.z, 0, CubeSphere.QUERY_HALF_MAX)
	var dimx := 2 * hx + 1
	var dimy := 2 * hy + 1
	var dimz := 2 * hz + 1
	var total := dimx * dimy * dimz
	if total <= 0 or total > CubeSphere.QUERY_CELLS_MAX:
		state["i"] = 0
		state["ids"] = PackedByteArray()
		return true                                   # over-cap ⇒ complete-empty (never-OOM backstop)
	var ids: PackedByteArray = state.get("ids", PackedByteArray())
	if ids.size() != total:
		ids.resize(total)
	var i := int(state.get("i", 0))
	var done_this := 0
	var plane := dimz * dimx
	while i < total and done_this < budget:
		var dy := i / plane
		var rem := i % plane
		var dz := rem / dimx
		var dx := rem % dimx
		var bid := block_id_at(center + Vector3i(dx - hx, dy - hy, dz - hz))
		ids[i] = bid if (bid >= 0 and bid <= 255) else 255   # u8 (BlockCatalog ids fit u8 today; clamp is a never-truncate-silently backstop)
		i += 1
		done_this += 1
	state["ids"] = ids                                # write back the CoW buffer
	state["i"] = i
	return i >= total

## Composed solidity — the MATERIAL half of the merged analytic-physics contract
## (INTEGRATION-DECISIONS §3): a cell is solid iff its material passes the solidity
## gate (`solidity_of(mat) >= 0.5`). Resolves the packed value ONCE, then gates on
## the material only — a shaped (ramp) cell IS solid; where inside the cell it
## collides is expressed by the interval functions (`_occ_span`), never by this
## boolean. Byte-identical to the old `!= AIR` test for the current world (AIR → 0.0,
## every core material → 1.0). `_cell_solid`/`is_solid` are aliases of this.
func cell_solid(cell: Vector3i) -> bool:
	return BlockCatalog.solidity_of(CellCodec.mat(cell_value_at(cell))) >= 0.5

## THE occupancy-composition helper (INTEGRATION-DECISIONS §3): material solidity
## GATES, modifier SHAPES. Returns the filled vertical interval (lo, hi) of packed
## cell value `v` at footprint (fx, fz); `Vector2.ZERO` = no occupancy (air / water /
## lava / powder_snow via the material gate, or a shape empty at this footprint).
## The four analytic queries and the collider all compose against this ONE helper,
## so the material gate and the shape test can never disagree. Full-cube today →
## (0, 1) for every solid cell, so callers reduce branch-for-branch to today's code
## (one extra solidity read); P5's ShapeCodec fills the sub-cube intervals.
func _occ_span(v: int, fx: float, fz: float) -> Vector2:
	if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:   # 1) MATERIAL GATE
		return Vector2.ZERO
	var sp := ShapeCodec.span(CellCodec.modifier(v), fx, fz)   # 2) SHAPE (modifier 0 -> (0,1))
	# 3) SNOW FILL (SNOW-ACCUMULATION §2.4): a filled ramp holds snow in its remainder up to the plane
	# `fill/10`, so the walkable surface is max(terrain shape, snow plane) — the player stands on the
	# combined surface everywhere by construction (floor_under/blocked/ceiling all compose against this).
	var fill := CellCodec.snow_fill(v)
	if fill != 0:
		return Vector2(0.0, maxf(sp.y, float(fill) / 10.0))
	return sp

## True if the cell was dug out (edit overlay says air). Used by fast column loops
## (fallback mesher tops, ground collider) that only care about air-vs-solid at/
## below the heightmap.
func is_removed(cell: Vector3i) -> bool:
	return _edits.get(_edit_key(cell), -1) == 0

## Highest y the player ever PLACED a block at in column (x, z); returns a deep
## negative sentinel when the column has no placements. (Bounds collider scans.)
func placed_top(x: int, z: int) -> int:
	return _placed_top.get(Vector2i(x, z), -0x40000000)

## Read-only view of the edit overlay (Vector3i -> int PACKED cell value; 0 = dug
## air, >0 = solid). The fallback mesher / structural collapse solver read placed (value > 0) cells
## from it and MUST project the material via CellCodec.mat (a bare id is a plain packed value, so it
## is identical today) rather than treating the raw value as a block id. FP-M1a: under FACETED the
## live overlay is (fid, cell)-keyed, so this projects the ACTIVE facet's edits back to Vector3i cells
## (the consumers' expectation); FLAT returns the live `_edits` by reference (byte-identical).
func placed_cells() -> Dictionary:
	return _overlay_v3i()

## WINDOW-keyed view of the edit overlay (Vector3i window cell → PACKED value) for the fallback
## mesher (COSMOS M3 §4.3). In FLAT_WORLD / no chart the overlay IS Vector3i-keyed, so this returns
## it directly (byte-identical, zero copy). In curved mode `_edits` is GLOBAL-int-keyed, so this
## unfolds each edit's global cell back into the CURRENT window: a home-face cell is (i−i_org, r,
## j−j_org); a neighbour-face edit in an edge strip is unfolded via CubeSphere.unfold_to_window so a
## block built just across a seam still renders in the extended window. Edits whose global cell is
## not reachable in this window (far off-face / corner quadrant) are omitted — they render once the
## home face flips to their face (hard restream). Built on demand; the mesher already iterates the
## whole overlay, so this adds no asymptotic cost.
func placed_cells_window() -> Dictionary:
	if _chart == null:
		return _overlay_v3i()   # FLAT: live `_edits`; FACETED: active-facet edits projected to Vector3i cells
	var out := {}
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var w := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if bool(w["found"]):
			out[Vector3i(int(w["x"]), int(g["r"]), int(w["z"]))] = _edits[k]
	return out

## True if column (x, z) has ANY overlay edit (dug or placed) — the collider's fast-path gate
## (PERF): an unedited column's overlay is empty, so the collider skips its per-cell scan there.
func is_edited_column(x: int, z: int) -> bool:
	return _edit_columns.has(Vector2i(x, z))

# --- loose-body gate (PERF, GroundCollider exploration-jerkiness fix) ----------
# The ground collider exists ONLY to catch loose VoxelBodies; the player moves analytically and
# never touches it. So the collider is gated on whether any loose body is present/near — with none,
# it does zero rebuild work. Every loose VoxelBody is a DIRECT child of this WorldManager (both
# spawn paths — spawn_loose(self, …) and VoxelBody._spawn_detached via get_parent()), so the set is
# just the VoxelBody children; deriving it on demand (no signal/_ready dependency) is robust in the
# game AND the headless verify (where _ready is deferred). The set is tiny (typically 0–a few), so
# the per-frame scan is negligible.

## Metres around a terrain/body edit within which dormant debris is woken (dormant-by-default
## reactivation). Generous enough to catch a local debris pile so a whole small stack reactivates
## together; a rare taller stack self-heals on the next nearby edit.
const _WAKE_RADIUS := 6.0

## Number of active loose VoxelBodies (debris) in the world.
func active_body_count() -> int:
	var n := 0
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if c is VoxelBody:
			n += 1
	return n

## True iff any loose VoxelBody exists at all (dormant or awake).
func has_active_bodies() -> bool:
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if c is VoxelBody:
			return true
	return false

## Number of AWAKE (simulating) loose bodies — dormant (frozen / sleeping) debris is excluded.
func awake_body_count() -> int:
	var n := 0
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if c is VoxelBody and (c as VoxelBody).is_awake():
			n += 1
	return n

## True iff an AWAKE loose VoxelBody is within `radius` columns (Chebyshev, horizontal) of `center`.
## THE collider gate (DORMANT-BY-DEFAULT): a FROZEN ground body or a SLEEPING wood body does NOT
## count, so once nearby debris settles the collider returns to idle even though the (now-static)
## bodies still sit there — a pile of settled debris near the player costs nothing. Only a moving/
## falling body keeps the collider active. A body's world column is its spawn cell offset by its
## rigid-body displacement (global_position), so a dropping/shoved body is tracked cheaply.
func has_active_bodies_near(center: Vector2i, radius: int) -> bool:
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or not vb.is_awake():
			continue                        # emptied (mid-free) or DORMANT → does not hold the collider on
		var home := _body_home_column(vb)
		# FP-FIXED-FRAME (§2.3): the collider gate is a LATTICE-column test; a debris body's lattice pose is its
		# LOCAL transform under ActiveFrame (== global_position when off / at identity → byte-identical).
		var gp := vb.position
		var wx := home.x + int(floor(gp.x))
		var wz := home.y + int(floor(gp.z))
		if maxi(absi(wx - center.x), absi(wz - center.y)) <= radius:
			return true
	return false

## The world column (wx, wz) of a representative AWAKE loose body within `radius` columns (Chebyshev)
## of `center`, or Vector2i(0x7fffffff, 0) if none. GroundCollider centres its bootstrap CORE on the
## actual faller (which may be a few blocks from the player — a break happens at reach distance)
## rather than on the player, so a small core reliably covers the body that needs ground. Mirrors the
## body-tracking of has_active_bodies_near exactly (same awake/home-column logic).
func active_body_column_near(center: Vector2i, radius: int) -> Vector2i:
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or not vb.is_awake():
			continue
		var home := _body_home_column(vb)
		# FP-FIXED-FRAME (§2.3): lattice column of the body = its LOCAL pose under ActiveFrame (see above).
		var gp := vb.position
		var wx := home.x + int(floor(gp.x))
		var wz := home.y + int(floor(gp.z))
		if maxi(absi(wx - center.x), absi(wz - center.y)) <= radius:
			return Vector2i(wx, wz)
	return Vector2i(0x7fffffff, 0)

## Wake every dormant loose body whose cells are within `radius` metres of world point `p` — the
## disturbance reactivation path (DORMANT-BY-DEFAULT): a break/collapse/placement near settled
## debris wakes it so it re-tests support and falls if undermined, else re-settles. Called on every
## terrain/body edit; comprehensive so a body can never be left floating with its support removed.
func wake_bodies_near(p: Vector3, radius: float) -> void:
	var r2 := radius * radius
	for c in _frame_host().get_children():   # FP-FIXED-FRAME: debris live under ActiveFrame when on, else self
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or vb.is_awake():
			continue                        # already awake → nothing to do
		# FP-FIXED-FRAME (§2.3): compare the disturbance point `p` (a LATTICE point — WM callers pass a lattice
		# cell centre; VoxelBody.break_cell now passes `transform * cell`) against the body's cells in its LATTICE
		# frame, i.e. its LOCAL transform under ActiveFrame (== global_transform when off / at identity).
		var xf := vb.transform
		for k: Vector3i in vb.cells:
			var wp: Vector3 = xf * Vector3(k.x + 0.5, k.y + 0.5, k.z + 0.5)
			if wp.distance_squared_to(p) <= r2:
				vb.wake()
				break                       # this body is awake now; move to the next
	return

## A representative local column (x, z) of a VoxelBody's cells (first key). Added to global_position
## it gives the body's current world column (coarse; enough for the gate radius).
func _body_home_column(vb: VoxelBody) -> Vector2i:
	for k: Vector3i in vb.cells:
		return Vector2i(k.x, k.z)
	return Vector2i(0, 0)

## Topmost still-solid column height at (x, z): the noise height, lowered past any
## blocks the player has broken from the top. Because every column is solid all
## the way down, this always finds a block — the ground is never hollow. (Ignores
## placed blocks ABOVE the heightmap; those are handled by placed_cells/placed_top.)
func effective_height(x: int, z: int) -> int:
	var h := col_height(x, z)
	while is_removed(Vector3i(x, h, z)):
		h -= 1
	return h

# --- COSMOS M3: curved-render integration — window→GLOBAL column projection (§4.3 / M2 follow-up) --
# The analytic curved-render consumers (the fallback mesher, GroundCollider, PerVoxelEnvironment)
# read TerrainConfig column functions on WINDOW coordinates. In curved mode a window column is NOT
# its global column (the floating origin offsets it, and near a seam it folds to a NEIGHBOUR face),
# so these MUST resolve the GLOBAL cell first or they build/read the wrong column at a non-zero
# origin. These wrappers convert window (x, z) → raw index via chart.raw_of (M_win, §5.3) — the edge fold happens
# inside TerrainConfig via LatticeNav when the column spills past an edge. FLAT_WORLD / no chart →
# the direct TerrainConfig call (byte-identical to the pre-M3 flat world).

## Surface height at WINDOW column (x, z), resolved on the GLOBAL cell (folds the origin, and an
## edge if the column spilled past one). Byte-identical to TerrainConfig.height_at in flat mode.
func col_height(x: int, z: int) -> int:
	if _chart == null:
		return TerrainConfig.height_at(x, z)
	var p := _chart.raw_of(x, z)                 # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
	return TerrainConfig.height_at(p.x, p.y)

## Column profile Vector4(g, biome, c, t) at WINDOW column (x, z), resolved on the GLOBAL cell.
func col_profile(x: int, z: int, pcache = null) -> Vector4:
	if _chart == null:
		return TerrainConfig.column_profile(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return TerrainConfig.column_profile(p.x, p.y, pcache)

## Smoothing SURFACE modifier at WINDOW column (x, z), resolved on the GLOBAL cell (GroundCollider).
func col_surface_modifier(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.surface_modifier(x, z, pcache)
	var p := _chart.raw_of(x, z)
	# COSMOS-FRAME-ORIENTATION §6: rotate the directional modifier into the window render frame so the
	# collider matches the mesh (resolve_cell rotates identically). Identity jinv → byte-identical.
	return ShapeCodec.rotate_modifier(TerrainConfig.surface_modifier(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## Smoothing CAP modifier at WINDOW column (x, z), resolved on the GLOBAL cell (GroundCollider).
func col_surface_cap_modifier(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.surface_cap_modifier(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return ShapeCodec.rotate_modifier(TerrainConfig.surface_cap_modifier(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## Packed snow stack (SNOW-ACCUMULATION §3.4) at WINDOW column (x, z), resolved on the GLOBAL cell so
## the collider's snow fill matches the surface/cap it folds. Byte-identical to TerrainConfig in flat mode.
func col_snow_stack_at(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.snow_stack_at(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return TerrainConfig.snow_stack_at(p.x, p.y, pcache)

## Packed SLOPE run (SHARP-SLOPE §3.6) at WINDOW column (x, z), resolved on the GLOBAL cell (the run
## decode via slope_run_range/_modifier_at is pure arithmetic, so only this column fetch needs folding).
func col_slope_run_of(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.slope_run_of(x, z, pcache)
	var p := _chart.raw_of(x, z)
	# COSMOS-FRAME-ORIENTATION §6: rotate the run's corner codes so the collider decodes the same rotated
	# slope the mesh renders (render == collision). lo/hi unchanged. Identity jinv → byte-identical.
	return TerrainConfig.rotate_slope_run(TerrainConfig.slope_run_of(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## The tree-overlay block at WINDOW cell (x, y, z), resolved on the GLOBAL column. FLAT_WORLD →
## direct. Curved: keyed on the global (i, j) so the same tree is seen from any window/origin (the
## across-a-real-3D-seam identity of a tree straddling a face edge is fallback-grade, §4.6).
func tree_block_at(x: int, y: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TreeGen.block_at(x, y, z, pcache)
	var p := _chart.raw_of(x, z)
	return TreeGen.block_at(p.x, y, p.y, pcache)

## The raw overlay value at WINDOW cell (folds to the global edit key), or −1 if unedited. THE
## point accessor the collider uses instead of `placed_cells().get(Vector3i, −1)` — that dict is
## GLOBAL-keyed in curved mode, so a window-Vector3i lookup would always miss (§1.3).
func overlay_at(cell: Vector3i) -> int:
	var e: int = _edits.get(_edit_key(cell), -1)
	if e < 0:
		return e
	return _overlay_window_modifier(cell, e)         # §6.4: de-canon into the window frame for the collider

## Break the block at `cell` (terrain, layers, tree cells, placed blocks alike).
## Returns the BROKEN BLOCK ID (>0) on success, 0 if the cell was already air.
## `from_pos` (the breaker's position) propagates to the collapse pass so any
## detached floating cluster gets a slight kick away from the breaker; pass
## Vector3.INF (default) for "no kick". Mirrors into the active render path, runs
## a local support analysis so undercut terrain drops as loose rigid bodies, then
## refreshes ground collision.
func break_terrain(cell: Vector3i, from_pos: Vector3 = Vector3.INF) -> int:
	if is_corner_locked_column(cell.x, cell.z):
		return 0                                       # M5c: the corner monument + its lock disc are unbreakable
	if _edits.get(_edit_key(cell), -1) == 0 or not cell_solid(cell):
		return 0
	# Snow first (SNOW-ACCUMULATION §2.5): a snow-FILLED ramp yields its snow BEFORE the terrain
	# beneath. The first break clears the fill nibble AND the snow_capped skin (the snow is gone) and
	# returns snow_block; the terrain ramp is re-exposed (still supported → no structural update), and
	# the NEXT break takes the terrain. Digging thus removes worldgen snow without partial digging (§1.6).
	var v0: int = cell_value_at(cell)
	if CellCodec.snow_fill(v0) != 0:
		var bare := CellCodec.with_snow_fill(v0, 0)
		bare = CellCodec.with_state(bare, CellCodec.state(bare) & ~CellCodec.STATE_SNOW_CAPPED)
		_write_cell(cell, bare)
		wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)
		if _ground != null:
			_ground.rebuild_now()
		return BlockCatalog.id_of(&"snow_block")
	var id: int = block_id_at(cell)     # capture the MATERIAL id BEFORE carving
	_write_cell(cell, 0)                # dig to air (0 = canonical air)
	_structural_update(cell, from_pos)  # only from the player break — never a spawn
	# Disturbance: wake dormant debris near the break so anything that just lost its support falls
	# (dormant-by-default reactivation). The new-body spawns from _structural_update are already awake.
	wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)
	if _ground != null:
		_ground.rebuild_now()
	return id

## Place a block into `cell`. `value` is a PACKED cell value (CellCodec) so a shaped
## partial cell (material + modifier — a ramp/slab, SUB-VOXEL-SMOOTHING §9) can be
## placed; a bare block id is a valid packed value meaning "full cube", so the
## historical `place_block(cell, id)` call site is unchanged. Fails (returns false,
## no state change) if the cell is not air (composed query), the MATERIAL is invalid
## (<=0 or >= count()) or non-solid (water/lava/powder_snow — WGC §6.3). On success
## writes the CANONICAL overlay value (canonicalization strips a modifier that can't
## apply, e.g. a corner-3 clamp), updates _placed_top, mirrors into the active render
## path and rebuilds the ground collider. Player-overlap is the CALLER's check.
func place_block(cell: Vector3i, value: int) -> bool:
	if is_corner_locked_column(cell.x, cell.z):
		return false                                   # M5c: no placing inside the corner lock disc
	var block_id := CellCodec.mat(value)
	if block_id <= BlockCatalog.AIR or block_id >= BlockCatalog.count():
		return false
	if BlockCatalog.solidity_of(block_id) < 0.5:
		return false                       # no placing water/lava/powder_snow from the hotbar (WGC §6.3)
	if cell_solid(cell):
		return false
	_write_cell(cell, value)              # _write_cell canonicalizes (full cube if value was a bare id)
	var key := Vector2i(cell.x, cell.z)
	var prev: int = _placed_top.get(key, -0x40000000)
	if cell.y > prev:
		_placed_top[key] = cell.y
	# The placement SUCCEEDS, then the structure is judged (SI §6): an over-tall
	# pillar crushes, an undercut/unsupported placement detaches. No breaker kick on
	# a placement collapse (from_pos = Vector3.INF).
	_structural_update(cell, Vector3.INF)
	wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)   # disturbance: reactivate nearby dormant debris
	if _ground != null:
		_ground.rebuild_now()
	return true

## THE single write choke point (VOXEL-DATA-STRUCTURE §7.2): the ONLY function
## that mutates a cell's overlay value, now owning ALL FOUR axes. break/place/collapse
## all route here. It canonicalizes the packed value (air-zeroing + P5/P6 hooks),
## stores it in `_edits`, SETTLES the cell's metadata, and mirrors the resulting
## MATERIAL into the active render path.
##
## Metadata settlement (the leak-proof invariant, §7.2/§16): a write DROPS the cell's
## existing metadata unless the SAME call supplies replacement `meta` for a block-entity
## material. break/place/collapse never pass `meta`, so they always drop+orphan any
## existing document — there is no code path that changes a cell's material and skips
## metadata cleanup, because there is only one write function. `set_state` re-passes the
## existing document (same material → block-entity) so it is PRESERVED without an orphan.
##
## Zero-cost default: with an empty `_meta` and no `meta` argument (today's every write),
## the settlement collapses to a single `is_empty()` check — gameplay stays byte-identical.
## `paint` (default true) mirrors the cell into the active render path immediately. It is
## set false ONLY by `load_bundle` on the module path, which coalesces the render into ONE
## bulk `try_set_block_data` pass (RMS §3.4) after the overlay is fully written — the overlay
## update itself (the gameplay truth) is unconditional.
func _write_cell(cell: Vector3i, packed: int, meta: Variant = null, paint: bool = true) -> void:
	# COSMOS-CORNER-CANONICAL (#69) companion edit-lock (SEPARABLE — see CORNER_EDIT_LOCK). Refuse a write
	# to a corner-quadrant window cell: the double-out wedge is a per-window sampling of canonical terrain
	# with no stable window identity to re-mirror. FLAT_WORLD (no chart) never reaches this → byte-identical.
	if CORNER_EDIT_LOCK and _chart != null:
		var _cp := _chart.raw_of(cell.x, cell.z)     # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
		if int(CubeSphere.fold_cell(_chart.face, _cp.x, _cp.y,
				CubeSphere.n_for(CubeSphere.HOME_BODY))["face"]) < 0:
			return
	# COSMOS M5c (§3): the corner-lock disc covers collapse / snowfall / sim writes at the choke point too.
	if is_corner_locked_column(cell.x, cell.z):
		return
	packed = CellCodec.canonical(packed)
	# COSMOS M2 / FP-M1a: the overlay + metadata key by the global edit key in curved mode, by the
	# (fid, cell) global int under FACETED, by the Vector3i window cell in plain FLAT_WORLD (byte-
	# identical). `_edit_columns` stays WINDOW-keyed (a collider fast-path index) and is re-keyed by −Δ
	# on a re-anchor (_shift_window_bookkeeping) / re-derived per facet on a crossing.
	var ek: Variant = _edit_key(cell)
	# FP-M1a §6.2 write-guard: under FACETED an edit key is ALWAYS the (fid, cell) packed int — a stray
	# Vector3i key would corrupt across a crossing. Debug-only (asserts strip in release); the headless
	# gate re-checks the whole overlay. FLAT/curved never trip this (FACETED is false there).
	assert(not CubeSphere.FACETED or typeof(ek) == TYPE_INT,
		"WorldManager._write_cell: a non-int edit key entered `_edits` under FACETED (FP-M1a §6.2)")
	if meta != null and BlockCatalog.has_block_entity(CellCodec.mat(packed)):
		_meta[ek] = meta                         # the one write that (re)sets metadata
	elif not _meta.is_empty():
		var old_meta: Variant = _meta.get(ek, null)
		if old_meta != null:
			_meta.erase(ek)                      # material change / break settles it
			block_entity_orphaned.emit(cell, old_meta)
	if not _edits.has(ek):
		_edit_columns[Vector2i(cell.x, cell.z)] = true   # first edit in this column (PERF index)
		# COSMOS-PERF UNATTENDED R5 (FP_EDIT_FID_INDEX): file the NEW key under its facet so a crossing rebuild
		# touches only this facet's edits. FACETED-only (ek is the (fid,cell) int); a value UPDATE to an existing
		# key leaves membership — and this index — unchanged, so it is maintained here at first-write only.
		if CubeSphere.FP_EDIT_FID_INDEX and CubeSphere.FACETED and _chart == null:
			var _fid: int = FacetAtlas.edit_key_fid(ek)
			var _bucket: Variant = _edits_by_fid.get(_fid)
			if _bucket == null:
				_bucket = {}
				_edits_by_fid[_fid] = _bucket
			(_bucket as Dictionary)[ek] = true
	# COSMOS-PERF FALL (FP_FLOOR_MEMO): this write changes the column's occupancy, so drop its cached topmost-floor
	# (break/place/collapse/snow all funnel here) — the next floor_under recomputes it exactly. No-op with the flag off.
	if CubeSphere.FP_FLOOR_MEMO and not _floor_top.is_empty():
		_floor_top.erase(Vector2i(cell.x, cell.z))
	# COSMOS-FRAME-ORIENTATION §6.4: store the directional modifier in its CANONICAL (true-face) frame so
	# it survives a flip; PAINT the window-frame value (the current render). No-op for a full cube.
	_edits[ek] = _overlay_canon_modifier(cell, packed)
	# docs/COSMOS-STRUCTURES-DESIGN.md (P0, §4.2): the ONE place a placed cell enters/changes — feed the structure
	# tracker so it maintains its 6-connected components incrementally (place / material-swap / overwrite-to-air). The
	# tracker itself filters non-qualifying (dug air, snow-family) materials. FACETED-only (ek is the (fid,cell) int);
	# null tracker (flag off) ⇒ one branch skip (byte-identical).
	if _structure_tracker != null and CubeSphere.FACETED and _chart == null:
		_structure_tracker.note_cell(ek, packed)
	# docs/COSMOS-FARTREE-CHOP-DESIGN.md §4.3 (FP_FT_SKIN_CHOP): if this edit is the trunk-base cell of its column's
	# procedural tree, the tree's chopped state just toggled — the facet's baked band/fine far-skin tiles are stale.
	# O(1) detect (one tree_info); the rung-3 analogue of FacetFarTrees' edits-rev rebuild re-arm. Off / no baker ⇒ no-op.
	if CubeSphere.FP_FT_SKIN_CHOP and _facet_tex != null and CubeSphere.FACETED and _chart == null:
		var _cu: Array = FacetAtlas.edit_key_unpack(int(ek))
		if _is_trunk_base_edit(int(_cu[0]), _cu[1]):
			_facet_tex.invalidate_far_skin(int(_cu[0]))
	if paint:
		_paint_cell(cell, packed)

# --- snowfall-sim support (SNOW-ACCUMULATION Decision 4) ------------------------
# Three tiny primitives the SnowfallSystem composes over the ONE write choke point. It never bypasses
# `_write_cell`; these only add the read + the baseline-revert + the debounced rebuild it needs.

## True iff `cell` currently carries an overlay edit (dug air OR a placed/sim value). The sim uses this to
## tell an in-place snow bump (already an edit) from ADDING a new snow cell (budget accounting), and to
## refuse burying a NON-snow edit.
func has_edit(cell: Vector3i) -> bool:
	return _edits.has(_edit_key(cell))               # COSMOS: fold to the global edit key (byte-identical in FLAT_WORLD)

## Drop `cell`'s overlay edit so it reverts to its pure GENERATED value, and repaint that value into the
## active render path. The sim calls this when a melting snow cell reaches its bare baseline: storing a
## baseline-equal edit would be wasted (§4.4 "never write a cell whose new value equals its generated
## value"), so the edit is removed instead. Safe for snow (no metadata); `_edit_columns` intentionally
## keeps its entry (it only ever grows — a stale empty-overlay column just costs the collider one skip).
func sim_revert_cell(cell: Vector3i) -> void:
	# COSMOS: erase by the global edit key and repaint the folded generated value (cell_value_at falls
	# through to the folded worldgen once the edit is gone). Byte-identical to main in FLAT_WORLD.
	var ek: Variant = _edit_key(cell)
	if _edits.erase(ek):
		# COSMOS-PERF FALL (FP_FLOOR_MEMO): reverting a cell to bare changes the column's occupancy — drop its memo.
		if CubeSphere.FP_FLOOR_MEMO and not _floor_top.is_empty():
			_floor_top.erase(Vector2i(cell.x, cell.z))
		# COSMOS-PERF UNATTENDED R5 (FP_EDIT_FID_INDEX): the ONLY `_edits` erase — drop the key from its facet bucket
		# so the index stays a byte-exact subset of `_edits`; retire the bucket when it empties (NEVER-OOM). Off / non-
		# FACETED ⇒ the index is empty and this is a no-op (byte-identical).
		if CubeSphere.FP_EDIT_FID_INDEX and CubeSphere.FACETED and _chart == null:
			var _fid: int = FacetAtlas.edit_key_fid(ek)
			var _bucket: Variant = _edits_by_fid.get(_fid)
			if _bucket != null:
				(_bucket as Dictionary).erase(ek)
				if (_bucket as Dictionary).is_empty():
					_edits_by_fid.erase(_fid)
		# docs/COSMOS-STRUCTURES-DESIGN.md (P0, §4.2): a reverted cell is no longer a placed structure cell — mark it
		# removed so the tracker debounces a bounded recluster (a removal can split a component). FACETED ⇒ ek is int.
		if _structure_tracker != null and CubeSphere.FACETED and _chart == null:
			_structure_tracker.note_removed(int(ek))
		# docs/COSMOS-FARTREE-CHOP-DESIGN.md §4.3 (FP_FT_SKIN_CHOP): the ONLY `_edits` erase — an erased trunk-base
		# edit UN-chops the tree; re-bake the facet's far skin so the tree returns (symmetric with _write_cell above).
		if CubeSphere.FP_FT_SKIN_CHOP and _facet_tex != null and CubeSphere.FACETED and _chart == null:
			var _cu: Array = FacetAtlas.edit_key_unpack(int(ek))
			if _is_trunk_base_edit(int(_cu[0]), _cu[1]):
				_facet_tex.invalidate_far_skin(int(_cu[0]))
		_paint_cell(cell, cell_value_at(cell))

## ONE debounced ground rebuild for the snowfall sim, run at a step's end iff a write happened (§4.3.5).
## The collider's own debounce coalesces further, and its loose-body gate means it does zero work unless a
## body is actually nearby — a settled pile near the player costs nothing.
## COSMOS-TREE-BUGS CHOP-LAG (FP_CHOP_DEBRIS_CALM): routed to the collider's LAZY channel instead of the
## fast player-edit one — this call fires every 0.5s of writing sim steps regardless of whether the player
## touched anything, and feeding the fast 15/60 debounce turned "background dirt happened somewhere" into a
## rebuild every ~0.25-1.0s for as long as any body sat nearby, jolting a settling body back awake (the
## rebuild⇄wake loop measured in probe_choplag S6). Off ⇒ the shipped fast rebuild_now(), byte-identical.
func sim_ground_rebuild() -> void:
	if _ground == null:
		return
	if CubeSphere.FP_CHOP_DEBRIS_CALM:
		_ground.rebuild_now_lazy()
	else:
		_ground.rebuild_now()

# --- per-cell metadata + state axis (VOXEL-DATA-STRUCTURE §7.2 / §3.1) -----------

## Serialized-metadata size cap per cell (§16): the unbounded axis by nature, so
## `set_metadata` refuses (and logs) any document over this. Chest-heavy legit docs
## sit far below it.
const META_MAX_BYTES := 16 * 1024

## Attach/replace the block-entity METADATA document at `cell`. Validates loudly and
## returns false (no state change) if: the cell's MATERIAL is not a block-entity
## material (`has_block_entity` false — incl. air), the document is not JSON-representable
## (§3.2: String keys; bool/int/float/String/Array/Dictionary values; NO Object refs, NO
## NaN/INF), or it exceeds the §16 size cap. Stores a DEEP COPY so later caller mutations
## cannot alias the stored document. Keeps the scalar axes (`_edits`) untouched; fires no
## orphan signal (an explicit update is not a drop).
func set_metadata(cell: Vector3i, meta: Dictionary) -> bool:
	var mat := CellCodec.mat(cell_value_at(cell))
	if not BlockCatalog.has_block_entity(mat):
		push_error("WorldManager.set_metadata: material %d at %s is not a block-entity material (rejected)" % [mat, cell])
		return false
	if not _metadata_dict_ok(meta):
		push_error("WorldManager.set_metadata: document at %s is not JSON-representable (Object/NaN/INF or non-String key) — rejected" % cell)
		return false
	if JSON.stringify(meta).to_utf8_buffer().size() > META_MAX_BYTES:
		push_error("WorldManager.set_metadata: document at %s exceeds the %d-byte cap — rejected" % [cell, META_MAX_BYTES])
		return false
	_meta[_edit_key(cell)] = meta.duplicate(true)
	return true

## The block-entity METADATA document at `cell`; an EMPTY dict when the cell carries
## none. Returns a DEEP COPY — mutating it never changes the stored document (route
## real updates through `set_metadata`).
func get_metadata(cell: Vector3i) -> Dictionary:
	var m: Variant = _meta.get(_edit_key(cell), null)
	return (m as Dictionary).duplicate(true) if m != null else {}

## True iff `cell` currently carries a metadata document.
func has_metadata(cell: Vector3i) -> bool:
	return _meta.has(_edit_key(cell))

## Set the STATE axis (bits 32..47) of `cell`, keeping its material + modifier and
## PRESERVING any metadata (the one write that does — §11). Returns false on air.
## The state bits are canonicalized/validated through `CellCodec._validate_state`, which masks
## them against the material's declared `state_layout` (M1: undeclared bits silently drop to 0;
## an UNRESOLVED placeholder keeps its bits permissively).
func set_state(cell: Vector3i, state_bits: int) -> bool:
	var v := cell_value_at(cell)
	var mat := CellCodec.mat(v)
	if mat == BlockCatalog.AIR:
		return false                             # air carries no state
	var new_packed := CellCodec.pack(mat, CellCodec.modifier(v), state_bits)
	# Re-pass the existing document so the choke point KEEPS it (same material → still a
	# block-entity) rather than orphaning it: set_state is a behavioural, not material, edit.
	_write_cell(cell, new_packed, _meta.get(_edit_key(cell), null))
	return true

## Evaluate the material state machine at `cell` and, if a transition fires, apply the new STATE
## bits (M1 snowy-world ADR §4.2 — the melt/freeze EVALUATOR primitive). Returns true iff the cell's
## state changed. This is the live, dormant-by-default machine: there is NO periodic tick / global
## sweep / disturbance hook in M1 — worldgen already produces the fixed point of the transition
## (cap and melt share ONE zero crossing), so a call at a generated cell does nothing; a warm column
## holding a stray capped value melts it, a cold column caps bare grass. First-triggered transition
## wins; a target naming a `state_layout` bit SETS that bit, a target naming the DEFAULT state name
## CLEARS all layout bits (the snow melts back). The write routes through set_state → _write_cell →
## `_edits` (overlay-persisted, re-meshed), authoritative over generation — a melt can never be
## un-melted by re-streaming (same guarantee as break/place). MAIN THREAD ONLY (writes the
## non-thread-safe `_edits`); never call from the voxel worker. The SET (freeze) edge self-gates to
## the exposed generated surface cell so a buried cappable cell can't spuriously freeze; a future
## non-surface transition would need its own condition rather than reusing that gate.
func apply_state_transitions(cell: Vector3i) -> bool:
	var v := cell_value_at(cell)
	var mat := CellCodec.mat(v)
	if mat == BlockCatalog.AIR:
		return false
	var def := BlockCatalog.def_of(mat)
	if def == null:
		return false
	var st := def.get_default_state()
	if st == null or st.transitions.is_empty():
		return false
	if environment == null:
		return false                                 # sim query not wired (deferred _ready) — nothing to sample
	var mask := BlockCatalog.state_mask_of(mat)
	var state_bits := CellCodec.state(v)
	# A deposition state (snow_capped) only forms on the EXPOSED generated surface cell, never on
	# buried material: a buried cappable cell (stone/sand underground) reads sub-zero ground
	# temperature and would otherwise spuriously freeze, breaking the "worldgen is the fixed point"
	# invariant. So the SET (freeze) edge is gated to the generated surface height; the CLEAR (melt)
	# edge is ungated — clearing a stray bit anywhere is always safe. (M1 conservative gate; the M2
	# disturbance tick will define the exposed-surface set including edits.)
	var is_surface_cell := cell.y == TerrainConfig.height_at(cell.x, cell.z)
	var sample := environment.sample(Vector3(cell) + Vector3(0.5, 0.5, 0.5))
	for t: VoxelStateTransition in st.transitions:
		if not t.is_triggered(sample):
			continue
		var idx := def.state_layout.find(t.to_state)
		var new_bits: int
		if idx >= 0:
			if not is_surface_cell:
				continue                             # a SET edge only fires on the exposed surface cell
			new_bits = state_bits | (1 << idx)       # target is a STATE-axis bit → set it
		elif t.to_state == st.state_name:
			new_bits = state_bits & ~mask            # target is the default state → clear the layout bits
		else:
			continue                                 # unresolvable target → try the next transition
		# First TRIGGERED-and-resolvable transition wins (disjoint predicates make this safe): apply
		# it if it changes the state, else report no change (idempotent).
		if new_bits != state_bits:
			return set_state(cell, new_bits)
		return false
	return false

## JSON-subset validator (§3.2): a metadata document restricted to String keys and
## bool/int/finite-float/String/Array/Dictionary values, recursively. Rejects Object
## references (they cannot serialize / cross threads) and NaN/INF (they break byte-stable
## round-trips). Pure/static so it is trivially testable.
static func _metadata_dict_ok(d: Dictionary) -> bool:
	for k: Variant in d.keys():
		if typeof(k) != TYPE_STRING:
			return false
		if not _metadata_value_ok(d[k]):
			return false
	return true

static func _metadata_value_ok(v: Variant) -> bool:
	match typeof(v):
		TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(v)                  # no NaN / INF (byte-stable round-trips)
		TYPE_ARRAY:
			for e: Variant in v:
				if not _metadata_value_ok(e):
					return false
			return true
		TYPE_DICTIONARY:
			return _metadata_dict_ok(v)
		_:
			return false                         # Object refs and every other type rejected

## Mirror one cell's PACKED value into the active render path (0 = carve to air).
## Shared by _write_cell so the godot_voxel / fallback plumbing lives in one place.
## The module path resolves the (material, modifier) to a baked appearance id (ARID,
## VDS §8.1) so a placed ramp/slab renders its shape; the fallback re-reads the world
## query when it remeshes the cell, so it only needs the cell coordinate. The caller
## (_write_cell) owns the `_edits` overlay; break/place own the ground rebuild.
func _paint_cell(cell: Vector3i, packed: int) -> void:
	if using_module and _module_world != null:
		_module_world.call("set_cell", cell, packed)
	elif _streamer != null:
		_streamer.remesh_cell(cell)

# --- COSMOS M2: the floating-origin chart + re-anchor (docs/COSMOS-PLANET-TOPOLOGY.md §3.2) -----
# The whole intra-face floating-origin mechanism. FLAT_WORLD keeps `_chart` null, so every method
# here is a byte-identical no-op (maybe_reanchor returns Vector3.ZERO, install_chart is never called
# by the live path). Curved mode installs a chart in _ready; the M2 verify injects one directly.

## Install (or replace) the floating-origin chart, switching the overlay to GLOBAL-key mode. Public
## so the verify suites can exercise the curved store without flipping the FLAT_WORLD const. Keeps
## TerrainConfig's active face and the per-voxel environment's chart in sync (§4.5 / §6.1) so the
## analytic curved-render queries fold window→global on the same face the choke points do.
func install_chart(chart: CosmosChart) -> void:
	_chart = chart
	if chart != null:
		TerrainConfig.set_active_frame(chart.face, CubeSphere.d4_of(chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1)
		if environment != null:
			environment.set_chart(chart)
		if _far != null:
			_far.set_chart(chart)   # COSMOS R1 (M5_REAL): keep the far's bake/align chart current
		_m5_sync_frame()   # COSMOS M5a: chart table (org/M_win/face axes) → true-position shader

## COSMOS M5a: push the per-FRAME camera frame (d̂_cam / y_cam / M_tangent + camera origin) into the
## true-position shader globals. Called by main.gd each frame in M5_RENDER mode. No-op without a chart.
func m5_push_camera(cam: Vector3) -> void:
	if _chart == null or not CubeSphere.M5_RENDER:
		return
	CosmosTruePlace.push_camera(_chart, cam)

## COSMOS R1/R2.2 (M5_REAL): drive the per-frame render alignment from the player WINDOW position. R1 (no
## epoch locked, far-only builds) levels the far under the camera. R2.2 (epoch locked, Design Z): the near +
## far are baked STATIC in the shared epoch frame and the CAMERA moves through them (m5_epoch_camera). We do
## NOT rotate the VoxelTerrain — godot_voxel inverts a singular basis when its transform is rotated (det==0
## spam), so the near blocks render at their baked epoch coords via identity placement and the far renders
## static: apply_alignment(IDENTITY) nets the far node's window offset back out (align_root = (I,−position)),
## so far tiles sit at epoch coords and still track re-anchors. No-op without the far / a chart.
func m5_real_update(player_pos: Vector3) -> void:
	if _chart == null or not CubeSphere.M5_REAL:
		return
	if not _epoch_frame.is_empty():
		if _far != null and _far.has_method("apply_alignment"):
			_far.apply_alignment(Transform3D.IDENTITY)
		return
	# R1 far-only fallback (no epoch locked): the far self-refreshes its frame and levels under the camera.
	if _far != null:
		_far.update_alignment(player_pos)

## Deprecated R1 name kept for call sites; forwards to the unified updater.
func m5_real_update_far(player_pos: Vector3) -> void:
	m5_real_update(player_pos)

## COSMOS R2.2 (Design Z): map the player's WINDOW-space camera transform into the static epoch render frame
## — camera_epoch = F⁻¹ · window_cam, where F = alignment_transform (epoch→window). The camera flies through
## the static baked planet at the player's true position/orientation. Physics, streaming and the viewer stay
## in window space (untouched); only the DISPLAYED camera moves. Returns window_cam unchanged until the epoch
## is installed. Interaction/aim stays window-space and gains the exact J⁻¹ map in R2.3.
func m5_epoch_camera(player_pos: Vector3, window_cam: Transform3D) -> Transform3D:
	if _chart == null or _epoch_frame.is_empty() or not CubeSphere.M5_REAL:
		return window_cam
	# Safety net #1 — the DOUBLE-OUT corner WEDGE: if the player stands in the impossible (both-out) quadrant,
	# place_true() returns the _WEDGE sentinel (1e18). alignment_transform folds that into F.origin, so F⁻¹
	# would fling the DISPLAYED camera to ~1e18 and the whole planet (near + far, both baked in the epoch
	# frame) leaves the frustum → a blank HUD-only screen. Fall back to the window camera this frame instead.
	# (The spawn is kept out of the wedge in main.gd; this guards a player who walks up to the 3-face vertex
	# before the M5c corner seal lands.)
	var pe := CosmosTruePlace.place_true(_chart, player_pos, _epoch_frame)
	if pe == CosmosTruePlace._WEDGE:
		return window_cam
	var f := CosmosTruePlace.alignment_transform(_chart, _epoch_frame, player_pos)
	# Safety net #2 — a degenerate basis (should not happen now camera_frame synthesises a valid corner
	# radial) → fall back rather than spam Basis.invert det==0.
	if absf(f.basis.determinant()) < 1.0e-6:
		return window_cam
	return f.affine_inverse() * window_cam

## COSMOS: true iff the window column (x, z) folds to the double-out corner WEDGE — an impossible cell with
## no sphere position (place_true → _WEDGE). Used by main.gd to keep the spawn off the wedge so the M5_REAL
## camera never starts at the 1e18 sentinel (blank screen). Always false in FLAT_WORLD / when no chart.
func is_wedge_column(x: int, z: int) -> bool:
	if _chart == null:
		return false
	return CosmosTruePlace.is_wedge(_chart, float(x), float(z))

## COSMOS M5c (docs/COSMOS-M5C-CORNER.md §3): true iff window column (x,z) is within CORNER_LOCK_R=8 raw
## cells of a cube vertex — ALL heights refused (bedrock monument + its ground annulus). Cell-CENTRE raw
## distance across the fold (each strip is a rigid isometry, so Euclidean raw distance is the chart metric).
## Flag- and chart-gated → FLAT / flag-off short-circuit before any raw math (byte-identical).
func is_corner_locked_column(x: int, z: int) -> bool:
	if _chart == null or not CubeSphere.M5C_CORNER:
		return false
	var p := _chart.raw_of_f(float(x) + 0.5, float(z) + 0.5)
	var c := CosmosCorner.nearest_corner(p.x, p.y, _chart.n)
	return CosmosCorner.corner_dist(p.x, p.y, c) <= float(CubeSphere.CORNER_LOCK_R)

## COSMOS M5c (§4): true iff window column (x,z) is HOME-NATIVE — both raw indices in [0, n), i.e. no edge
## fold. main._find_flat prefers these under M5C_CORNER so the spawn does not fire the eager flip on frame 1.
func is_home_native_column(x: int, z: int) -> bool:
	if _chart == null:
		return false
	var p := _chart.raw_of(x, z)
	return p.x >= 0 and p.x < _chart.n and p.y >= 0 and p.y < _chart.n

## COSMOS M5c (docs/COSMOS-M5C-CORNER.md §5) — THE runtime corner seal, called each physics frame after the
## flip. Given the player's window position + velocity, returns a relocation Dictionary the player applies, or
## {} for "no action". Three cases (all in the continuous RAW frame; window↔raw via the chart):
##   1. DOUBLE-OUT column (wedge — §7 makes this near-unreachable): apply the §6 seam GLUE to the real strip.
##   2. inside the R_b anomaly cylinder: the §5.2 bisector TELEPORT (or nothing in barrier mode — S5 blocks entry).
##   3. else: {}.
## Flag/chart-gated → FLAT / flag-off is a pure no-op. Physics stays window-space; under M5_REAL the displayed
## camera follows next frame (set_render_camera), and the exit is never in the wedge so m5_epoch_camera is finite.
func m5c_corner_check(pos: Vector3, vel: Vector3) -> Dictionary:
	if _chart == null or not CubeSphere.M5C_CORNER:
		return {}
	var n := _chart.n
	var fx0 := int(floor(pos.x))
	var fz0 := int(floor(pos.z))
	# case 1 — defensive seam glue for a double-out (wedge) column: total at any radius, radius/height preserving.
	if is_wedge_column(fx0, fz0):
		var pf := _chart.raw_of_f(pos.x, pos.z)
		var g := CosmosCorner.glue_raw(pf.x, pf.y, n)
		var wg := _chart.window_of_f(g["px"], g["py"])
		return _glue_reloc(pf, Vector2(g["px"], g["py"]), wg, pos, vel, n)
	# case 2 — inside the R_b anomaly cylinder.
	var pr := _chart.raw_of_f(pos.x, pos.z)
	var c := CosmosCorner.nearest_corner(pr.x, pr.y, n)
	if CosmosCorner.corner_dist(pr.x, pr.y, c) >= CosmosCorner.R_B:
		return {}
	if not CubeSphere.M5C_TELEPORT:
		return _barrier_reloc(pr, c, pos, vel)     # §8 solid barrier: clamp to the cylinder, kill inward velocity
	var t := CosmosCorner.teleport_raw(pr.x, pr.y, n)
	var w_out := _chart.window_of_f(t["px"], t["py"])
	var beta: float = t["beta"]
	var si: float = t["si"]
	var sj: float = t["sj"]
	var w_out2 := _chart.window_of_f(t["px"] + si * cos(beta), t["py"] + sj * sin(beta))
	var r_out := (w_out2 - w_out)
	r_out = r_out.normalized() if r_out.length() > 1.0e-9 else Vector2(1, 0)
	# heading in: the horizontal velocity, or (stationary) inward toward the vertex.
	var v_h := Vector2(vel.x, vel.z)
	var d_in: Vector2
	if v_h.length() > 0.01:
		d_in = v_h.normalized()
	else:
		var w_v2 := _chart.window_of_f(c.x, c.y)
		var inward := w_v2 - Vector2(pos.x, pos.z)
		d_in = inward.normalized() if inward.length() > 1.0e-6 else r_out
	var yaw_delta := Vector3(d_in.x, 0.0, d_in.y).signed_angle_to(Vector3(r_out.x, 0.0, r_out.y), Vector3.UP)
	# de-embed: never below the exit column's surface; keep vertical velocity; re-aim horizontal speed outward.
	var y_out := maxf(pos.y, float(effective_height(int(floor(w_out.x)), int(floor(w_out.y))) + 1) + 0.01)
	var speed := v_h.length()
	return {
		"pos": Vector3(w_out.x, y_out, w_out.y),
		"vel": Vector3(r_out.x * speed, vel.y, r_out.y * speed),
		"yaw_delta": yaw_delta,
	}

## COSMOS M5c (§8): the solid ENERGY BARRIER fallback (M5C_TELEPORT=false). Clamp the player to the R_b
## cylinder surface along their radial from the vertex and remove the inward velocity component — a "you
## cannot enter" wall over the same full-height cylinder. All §7 invariants keep (the player never gets
## inside R_b, so never double-out). No teleport, no yaw change.
func _barrier_reloc(pr: Vector2, c: Vector4, pos: Vector3, vel: Vector3) -> Dictionary:
	var u := Vector2(pr.x - c.x, pr.y - c.y)
	u = u.normalized() if u.length() > 1.0e-6 else Vector2(1, 0)
	var p_out := Vector2(c.x + u.x * (CosmosCorner.R_B + 0.02), c.y + u.y * (CosmosCorner.R_B + 0.02))
	var w_out := _chart.window_of_f(p_out.x, p_out.y)
	var w_v := _chart.window_of_f(c.x, c.y)
	var r_hat := (w_out - w_v)
	r_hat = r_hat.normalized() if r_hat.length() > 1.0e-6 else Vector2(1, 0)
	var v_h := Vector2(vel.x, vel.z)
	var v_in := v_h.dot(r_hat)
	if v_in < 0.0:
		v_h -= r_hat * v_in                       # strip the inward component; keep tangential + vertical
	return {"pos": Vector3(w_out.x, pos.y, w_out.y), "vel": Vector3(v_h.x, vel.y, v_h.y), "yaw_delta": 0.0}

## COSMOS M5c (§6): the UNIVERSAL seam glue for non-flipping entities. Each physics frame, any AWAKE VoxelBody
## whose column is double-out (wedge — a fast projectile/debris can cross a seam ray far outside R_b) is mapped
## back through the ±90° B–C seam identification: position + linear velocity, radius/height/speed preserving.
## The wedge is thus unreachable by anything, at any radius. Zero cost when nothing is awake / flag off.
func m5c_glue_bodies() -> void:
	if _chart == null or not CubeSphere.M5C_CORNER:
		return
	var n := _chart.n
	# FP-FIXED-FRAME: scan under the debris host for consistency. This path is chart-gated (M5c, curved-only) and
	# the fixed frame requires FACETED (⇒ chart null), so it never runs with the frame on — but routing through the
	# host keeps a single debris-parent seam. Debris stay under WM@identity here, so global_position is unchanged.
	for ch in _frame_host().get_children():
		if not (ch is VoxelBody):
			continue
		var vb := ch as VoxelBody
		if not vb.is_awake():
			continue
		var gp := vb.global_position
		if not is_wedge_column(int(floor(gp.x)), int(floor(gp.z))):
			continue
		var pf := _chart.raw_of_f(gp.x, gp.z)
		var g := CosmosCorner.glue_raw(pf.x, pf.y, n)
		var wg := _chart.window_of_f(g["px"], g["py"])
		var c := CosmosCorner.nearest_corner(pf.x, pf.y, n)
		var w_v := _chart.window_of_f(c.x, c.y)
		var r_old := Vector2(gp.x, gp.z) - w_v
		var r_new := wg - w_v
		var lv := vb.linear_velocity
		if r_old.length() > 1.0e-6 and r_new.length() > 1.0e-6:
			var ang := Vector3(r_old.normalized().x, 0.0, r_old.normalized().y) \
				.signed_angle_to(Vector3(r_new.normalized().x, 0.0, r_new.normalized().y), Vector3.UP)
			var vh := Vector2(lv.x, lv.z).rotated(ang)
			lv = Vector3(vh.x, lv.y, vh.y)
		vb.global_position = Vector3(wg.x, gp.y, wg.y)
		vb.linear_velocity = lv

## §6 glue relocation for the (rare) double-out player: move to the glued strip window position, rotate the
## horizontal velocity + yaw by the old→new window-radial angle. Height/vertical velocity preserved. The next
## frame's m5c_corner_check handles the anomaly if the glued position is still inside R_b.
func _glue_reloc(pf: Vector2, pnew: Vector2, wnew: Vector2, pos: Vector3, vel: Vector3, n: int) -> Dictionary:
	var c := CosmosCorner.nearest_corner(pf.x, pf.y, n)
	var w_v := _chart.window_of_f(c.x, c.y)
	var r_old := (Vector2(pos.x, pos.z) - w_v)
	var r_new := (wnew - w_v)
	var yaw_delta := 0.0
	var vel_out := vel
	if r_old.length() > 1.0e-6 and r_new.length() > 1.0e-6:
		var ro := r_old.normalized()
		var rn := r_new.normalized()
		yaw_delta = Vector3(ro.x, 0.0, ro.y).signed_angle_to(Vector3(rn.x, 0.0, rn.y), Vector3.UP)
		var v_h := Vector2(vel.x, vel.z).rotated(yaw_delta)
		vel_out = Vector3(v_h.x, vel.y, v_h.y)
	return {"pos": Vector3(wnew.x, pos.y, wnew.y), "vel": vel_out, "yaw_delta": yaw_delta}

## COSMOS M5a: push the chart-orientation + 5-chart fold TABLE (org / M_win / face axes) into the true-
## position shader globals. Called after every frame change (init / install_chart / flip / reanchor).
## Guarded on M5_RENDER so the default (and the CosmosBend curved mode) never touch these globals.
func _m5_sync_frame() -> void:
	if _chart == null or not CubeSphere.M5_RENDER:
		return
	CosmosTruePlace.set_chart_table(_chart)   # single-writer: packs the table + applies to every M5 material this pass

## The active chart, or null in FLAT_WORLD. Read-only accessor.
func chart() -> CosmosChart:
	return _chart

## DEV (task #66): the 4 CUBE-FACE BORDER lines of the current home face, in WINDOW space, for the border
## overlay. The home face spans raw i,j ∈ [0, n]; each edge's two endpoints map to window space through the
## chart (COSMOS-FRAME-ORIENTATION §5.3: window = M_win⁻¹·(raw − org), the `window_of` helper). A C4 M_win
## keeps every edge axis-aligned but may SWAP which window axis it is constant along, so derive axis/pos/lo/hi
## from the mapped endpoints rather than assuming i↔x. M_win = I reproduces the old x=−i_org … lines exactly.
## Recomputed from the LIVE chart (org + M_win shift on re-anchor + flip), so callers poll each frame. Returns
## [] in FLAT_WORLD / with no chart. Each entry: {axis:"x"|"z", pos, lo, hi} — pos the constant window coord.
func cosmos_border_lines() -> Array:
	if _chart == null:
		return []
	var n := _chart.n
	var edges := [[Vector2i(0, 0), Vector2i(0, n)],   # raw i = 0 (WEST)
		[Vector2i(n, 0), Vector2i(n, n)],             # raw i = n (EAST)
		[Vector2i(0, 0), Vector2i(n, 0)],             # raw j = 0 (SOUTH)
		[Vector2i(0, n), Vector2i(n, n)]]             # raw j = n (NORTH)
	var out: Array = []
	for e: Array in edges:
		var w1: Vector2i = _chart.window_of(e[0].x, e[0].y)
		var w2: Vector2i = _chart.window_of(e[1].x, e[1].y)
		if w1.x == w2.x:                              # constant window x → a vertical "x" line over z
			out.append({"axis": "x", "pos": float(w1.x), "lo": float(mini(w1.y, w2.y)), "hi": float(maxi(w1.y, w2.y))})
		else:                                         # constant window z → a horizontal "z" line over x
			out.append({"axis": "z", "pos": float(w1.y), "lo": float(mini(w1.x, w2.x)), "hi": float(maxi(w1.x, w2.x))})
	return out

## DEV (task #75): window cells of the DOUBLE-OUT CORNER WEDGE near `center`, on a grid of `spacing`,
## within `span` half-extent — so the dev overlay can mark the known-weird corner quadrant DISTINCTLY (RED)
## and the user can tell the §4.6/§5.4 corner echo from a real bug while walking around. A wedge cell is one
## whose RAW index (raw_of, M_win) is out of range in BOTH axes → fold_cell returns face −1 (the same
## predicate the M4 edit-lock uses). Recomputed each frame from the LIVE chart so it tracks flips/re-anchors
## like the border pillars. Returns [] in FLAT_WORLD / no chart (the overlay is then never built — byte-identical).
func cosmos_wedge_cells(center: Vector3, span: float, spacing: float) -> Array:
	if _chart == null:
		return []
	var out: Array = []
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var cx := int(floor(center.x))
	var cz := int(floor(center.z))
	var step := maxi(int(spacing), 1)
	var half := int(span)
	var x := cx - half
	while x <= cx + half:
		var z := cz - half
		while z <= cz + half:
			var p := _chart.raw_of(x, z)
			if int(CubeSphere.fold_cell(_chart.face, p.x, p.y, n)["face"]) < 0:
				out.append(Vector2i(x, z))
			z += step
		x += step
	return out

## COSMOS M2 (§3.2): re-anchor the floating origin if the player has walked past the trigger.
## Returns the WORLD-space shift the caller (the player) must SUBTRACT from its position so the
## world stays continuous — Vector3.ZERO when there is no chart or no shift is due (FLAT_WORLD →
## byte-identical no-op). The shift is an EXACT INTEGER translation of the window origin: existing
## edits (global-keyed) are untouched, no cell changes its window identity relative to the player,
## no content re-streams (pop = 0). Render nodes carry window-space geometry, so they are translated
## by −Δ to keep their already-built meshes at the same world position while the origin moves.
func maybe_reanchor(player_pos: Vector3) -> Vector3:
	# COSMOS FP-FIXED-FRAME re-anchor (§3 / §10 decision 1): the curved `_chart` path below is a byte-identical no-op
	# under FACETED (no chart is built — §1.2), so the fixed frame gets its OWN faceted floating-origin re-anchor.
	# `player_pos` is the player's RENDERED-ABSOLUTE position (player.global_position); the faceted path slides every
	# absolute node toward the origin and carries the player via the ActiveFrame, so it returns ZERO (the caller
	# subtracts nothing — unlike the chart path where the caller compensates its own global_position).
	if _fixed_frame_on():
		_maybe_reanchor_faceted(player_pos)
		return Vector3.ZERO
	if _chart == null or not _chart.needs_reanchor(player_pos):
		return Vector3.ZERO
	var d := _chart.reanchor(player_pos)
	if d == Vector2i.ZERO:
		return Vector3.ZERO
	var shift := Vector3(float(d.x), 0.0, float(d.y))
	_shift_window_bookkeeping(d)
	if _module_world != null:
		_module_world.position -= shift
	if _streamer != null:
		_streamer.position -= shift
	if _ground != null:
		_ground.position -= shift
	# The far layer shares the near field's global-index frame, so it re-anchors by the SAME −Δ:
	# already-built (global-coord) tiles keep their world position and stay aligned with the near
	# surface (Fable Stage 1). Any live post-flip cover is a child, so it rides along automatically.
	if _far != null:
		_far.position -= shift
	_m5_sync_frame()   # COSMOS M5a: the reanchor moved _chart.org → refresh the true-position chart table
	return shift

## COSMOS FP-FIXED-FRAME faceted floating-origin re-anchor (docs/COSMOS-FIXED-FRAME-DESIGN.md §3 / §10 decision 1).
## Tracks the Phase-0 |player_abs| telemetry guard, and — ONLY when the rendered-absolute magnitude exceeds the
## trigger (never at R = 3072; large-planet headroom) — slides every absolute node back toward the origin by an
## INTEGER shift so f32 render/physics precision stays bounded. Fires far less often than a crossing; one PlanetRoot
## re-place per shift is acceptable (§3). The shift is exact-integer so no lattice/edit identity changes.
func _maybe_reanchor_faceted(player_global: Vector3) -> void:
	var mag := player_global.length()
	if mag > _player_abs_max:
		_player_abs_max = mag                       # Phase-0 telemetry: track the max |player render-abs| seen live
	if mag < CubeSphere.REANCHOR_TRIGGER_BLOCKS:
		return
	# Shift by the player's rendered-absolute position ROUNDED to whole blocks → the player lands near the origin,
	# and every absolute quantity is an exact integer translation (edits are (fid,cell)-keyed → wholly untouched).
	var a := Vector3(roundf(player_global.x), roundf(player_global.y), roundf(player_global.z))
	if a == Vector3.ZERO:
		return
	_apply_anchor_shift(a)

## Apply an integer floating-origin shift `a`: slide PlanetRoot (+ its FacetSlots + LOD tiles — ONE mesh-block
## re-place), the far ring, the per-facet gravity volumes, and the ActiveFrame (hence the player, GroundCollider,
## debris and the player-parented VoxelViewer, whose LOCAL/lattice poses are all UNTOUCHED) each by −a. Every node's
## `global + active_anchor_offset()` is therefore invariant — the physical world does not move; only the render
## origin does. Exposed (non-underscore-free) so the headless gate can force a shift directly (the trigger never
## fires at R = 3072). No-op unless the fixed frame is on.
func _apply_anchor_shift(a: Vector3) -> void:
	if not _fixed_frame_on():
		return
	_anchor_offset += a
	# 1. PlanetRoot (every FacetSlot + the LOD-tile layer ride it) — the ONE godot_voxel re-place, rare by construction.
	if _module_world != null and _module_world.has_method("shift_anchor"):
		_module_world.call("shift_anchor", a)
	# 2. Far ring (its mesh is ABSOLUTE) rides the same shift; the offset survives crossings (set_active folds it in).
	if _facet_ring != null and _facet_ring.has_method("shift_anchor"):
		_facet_ring.shift_anchor(a)
	# 2b. Skin tier (its mesh is ABSOLUTE too) rides the same shift, exactly like the far ring.
	if _skin != null:
		_skin.call("shift_anchor", a)
	# 3. ActiveFrame origin drops by a (basis unchanged); player/GroundCollider/debris/viewer keep their lattice locals.
	if _active_frame != null:
		_active_frame.position -= a
	# 4. Per-facet gravity volumes are placed in absolute space → slide each by −a (direction is translation-invariant).
	for f in _gravity_areas.keys():
		var ga: Area3D = _gravity_areas[f]
		if is_instance_valid(ga):
			ga.position -= a

## COSMOS M3 (§4.5): the home-face flip. When the player has crossed FLIP_HYST cells PAST a face
## edge, re-base the window onto the neighbour face (chart.flip) and HARD-RESTREAM the local region.
## Returns true iff a flip happened (FLAT_WORLD / no chart / not past an edge → false, a no-op).
##
## Teleport-free + edit-preserving BY CONSTRUCTION: chart.flip keeps the player's window position
## unchanged (its world point is the same global cell), and every edit is GLOBAL-keyed so it is
## found again by its unchanged key from the new home face. Worldgen determinism holds because a
## global cell resolves through _curved_profile identically regardless of which window/home face
## reaches it (§8.2). The fallback path drops + rebuilds its chunks at the normal budget; the module
## COSMOS FS-W (docs/COSMOS-FACET-SEAMS-V2.md §3): is the player genuinely PAST a ridge (own_dist < −1, well beyond
## the −0.1 commit line)? Used to void the crossing cooldown so a corner zig-zag can never strand them in masked space.
func _past_ridge_deep(fid: int, pos: Vector3) -> bool:
	for slot in 4:
		if FacetAtlas.own_dist(fid, slot, pos.x, pos.y, pos.z) < -1.0:
			return true
	return false

## COSMOS FS-W (§3): resolve a grid-corner crossing BY DIRECTION when the single-edge landing fails containment.
## Candidates = the crossed edge-neighbours ∪ the diagonal facet the player's world direction lands in
## (FacetAtlas.facet_of_dir_body — the classifier oracle). Commit to the candidate whose reframed landing is DEEPEST
## inside (argmax over candidates of the min-slot own_dist at the reframe), provided that best is not itself past a
## ridge by more than FACET_CORNER_SLACK (keeps the player clear of the −3 wall). Returns {"to","np"} or {} to defer.
func _corner_commit(fid: int, pos: Vector3) -> Dictionary:
	var crossed := []
	for slot in 4:
		if FacetAtlas.own_dist(fid, slot, pos.x, pos.y, pos.z) < -FACET_CROSS_HYST:
			crossed.append(slot)
	if crossed.is_empty():
		return {}
	var cands := {}                                    # dedup by fid
	for slot in crossed:
		cands[FacetAtlas.seam_neighbour(fid, slot)] = true
	# The diagonal (3-facet corner) the player is heading into — the direction oracle resolves it without the
	# fragile seam_neighbour-composition, and doubles as the §3 cross-check.
	var w := FacetAtlas.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	var fdir := FacetAtlas.facet_of_dir_body(FacetAtlas.body_of_fid(fid),
		CubeSphere.DVec3.new(w[0], w[1], w[2]).normalized())
	if fdir >= 0 and fdir != fid:
		cands[fdir] = true
	var best_to := -1
	var best_np := []
	var best_score := -INF
	for c in cands:
		var cnp := FacetAtlas.reframe_position64(fid, c, pos.x, pos.y, pos.z)
		var mind := INF
		for bslot in 4:
			mind = minf(mind, FacetAtlas.own_dist(c, bslot, cnp[0], cnp[1], cnp[2]))
		if mind > best_score:
			best_score = mind
			best_to = c
			best_np = cnp
	if best_to < 0 or best_score < -(FACET_CROSS_HYST + FACET_CORNER_SLACK):
		return {}                                      # nothing lands clear of the wall → defer one tick
	return {"to": best_to, "np": best_np}

## COSMOS FACETED §6.1 — the crossing handoff. When the player walks past an active-facet ridge (signed own_dist
## < −HYST, one-sided so jitter can't double-fire), re-frame them onto the neighbour facet: switch the active
## facet and return the f64-EXACT reframed position + the dihedral yaw twist for Player.apply_reframe. FP3a: the
## reframe + active-facet switch (the correctness core, gated by cross-and-return byte-identity). FP3b adds the
## module restream (M4 cover), the far-ring re-placement (rigid, no regen), and debris re-frame. {} = no crossing.
## `h_speed`/`grounded` (docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md §2): optional hints for
## FP_UPVECTOR_FACET_HEAL's strip resolver (§below). Defaults (0.0 / false) are the conservative "never heal"
## case, so an omitted-hint caller is unaffected even if the flag is on; flag off ⇒ never consulted at all.
func maybe_cross_facet(player_pos: Vector3, h_speed: float = 0.0, grounded: bool = false) -> Dictionary:
	if not CubeSphere.FACETED:
		return {}
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return {}
	# COSMOS-PERF UNATTENDED R3 (FP_ALT_REGIME): the altitude regime gate — the §0-W3 killer. `_update_alt_regime`
	# (run first, in update_streaming) owns the latch; here we only ACT on it. Two one-shot cases take priority over the
	# whole crossing pipeline:
	#   • RE-ENTRY (just descended below the gate): do the ONE restore redesignation onto the true sub-camera facet so a
	#     landing has terrain, then hand off to normal crossings + FP_LANDING_STREAM_KICK below the gate.
	#   • ORBITAL (frozen): return early — NO redesignation / _rebuild_window_indices / 128→96 shrink-snap / gravity /
	#     collider work. None of it is on screen at altitude (draws ≈ 30 = shell + sky). This is the fall's phys_ms.
	# Placed before the cooldown/ridge scan so the freeze is total and the restore is not gated by a stale cooldown.
	# Flag off ⇒ neither branch is reachable (`_alt_reentry_pending`/`_alt_orbital` never set) — byte-identical.
	if CubeSphere.FP_ALT_REGIME:
		if _alt_reentry_pending:
			_alt_reentry_pending = false
			return _alt_reentry_restore(fid, player_pos)
		if _alt_orbital:
			return {}
	# FP-S1(c): cooldown — after a committed crossing, suppress the next FACET_CROSS_COOLDOWN calls so a crossing
	# can never re-fire immediately (ridge-jitter / residual oscillation). A genuine sequential crossing traverses
	# the whole facet (many ticks ≫ cooldown), so this never blocks a legitimate crossing.
	if _cross_cooldown > 0:
		_cross_cooldown -= 1
		# COSMOS FS-W (docs/COSMOS-FACET-SEAMS-V2.md §3): the cooldown suppresses −0.1 ridge jitter — it must NOT
		# strand the player deep in masked space. If they are genuinely PAST a ridge (own_dist < −1) fall through
		# and commit this tick (the corner zig-zag case). Flag off ⇒ the shipped unconditional return (byte-identical).
		if not (CubeSphere.FP_CROSS_CORNER_COMMIT and _past_ridge_deep(fid, player_pos)):
			return {}
	for slot in 4:
		var s := FacetAtlas.own_dist(fid, slot, player_pos.x, player_pos.y, player_pos.z)
		if s < -FACET_CROSS_HYST:
			var to: int = FacetAtlas.seam_neighbour(fid, slot)
			var np := FacetAtlas.reframe_position64(fid, to, player_pos.x, player_pos.y, player_pos.z)
			# FP-S1(c) containment: only commit if the reframed landing is INTERIOR to ALL FOUR of B's ridges —
			# concretely own_dist(B, bslot, np) >= -HYST for every bslot, i.e. the landing would NOT itself
			# immediately re-fire a crossing. A genuine mid-edge crossing lands deep inside B (the welded ridge at
			# ~+HYST by seam complementarity, the other three far positive), so it ALWAYS passes. Near a corner the
			# player is past TWO of A's ridges, so the landing sits past one of B's other ridges (< -HYST) → this
			# slot would ping-pong B→C→B every tick (the R3 storm). Skip it; a later tick (once the player walks
			# clearly into one facet) or a better slot resolves it. Deferring a corner is strictly safer than a
			# storm — the far ring still draws the planet and the analytic floor still carries the player.
			var contained := true
			for bslot in 4:
				if FacetAtlas.own_dist(to, bslot, np[0], np[1], np[2]) < -FACET_CROSS_HYST:
					contained = false
					break
			if not contained:
				# COSMOS FS-W (§3): a grid-corner landing failed containment. Instead of deferring into the −3 wall,
				# resolve the destination BY DIRECTION: the facet (crossed edge-neighbours ∪ their diagonal via
				# facet_of_dir) whose reframed landing is DEEPEST inside (argmax of min-slot own_dist). Off ⇒ the
				# shipped `continue` (byte-identical).
				if not CubeSphere.FP_CROSS_CORNER_COMMIT:
					continue
				var cc := _corner_commit(fid, player_pos)
				if cc.is_empty():
					continue                       # tie / all too shallow → defer one tick (as shipped)
				to = int(cc["to"])
				np = cc["np"]
			return _commit_facet_change(fid, to, np, slot)
	# COSMOS UP-VECTOR FACET-DESYNC FIX (FP_UPVECTOR_FACET_HEAL, docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md
	# §2): the shipped scan above found nothing to commit (no slot triggered, or every triggered slot deferred) —
	# try the soil-ownership resolver for a near-stationary grounded player sitting in the sub-hysteresis strip.
	# Inside the SAME cooldown gate as the scan above, so it can never re-fire faster than a normal crossing. Off
	# ⇒ unreached (one flag compare) ⇒ byte-identical.
	if CubeSphere.FP_UPVECTOR_FACET_HEAL:
		var heal := _upvector_strip_heal(fid, player_pos, h_speed, grounded)
		if not heal.is_empty():
			return heal
	return {}

## COSMOS UP-VECTOR FACET-DESYNC FIX (FP_UPVECTOR_FACET_HEAL, docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md
## §2) — re-own the facet you stand on. Called only from `maybe_cross_facet`'s tail, after its own crossing-law
## slot scan found nothing to commit. A near-stationary, grounded player sitting in the sub-hysteresis strip
## (§1.2) has the SOIL cell under their feet junction-masked to a neighbour that renders it at its own
## orientation — commit the crossing the soil law already implies, through the same blessed
## `_commit_facet_change` path (ActiveFrame/up + pool/far-ring/gravity flip together, the SAME commit
## `_alt_reentry_restore` above uses). Returns the same dict shape a normal crossing does (consumed by the
## caller's `apply_reframe`), or {} (no heal — deferred exactly like a normal corner defer). Read-only w.r.t.
## position/`_pos_fid` — the crossing dict is the only output; `apply_reframe` remains the sole pose writer.
func _upvector_strip_heal(fid: int, pos: Vector3, h_speed: float, grounded: bool) -> Dictionary:
	# Cost-ordered guards (§2): a walking/airborne player can never be trapped (crosses the ≤0.33-block strip in
	# one physics step) — reject before touching the atlas at all.
	if not grounded or h_speed >= UPVECTOR_HEAL_MAX_SPEED:
		return {}
	# The SAME plane-dot math the shipped slot scan above already ran (one compare per slot); beyond NEAR_RIDGE
	# no crossing-law/mask disagreement is geometrically possible (§1.2's derived bound).
	var own_min := INF
	for slot in 4:
		own_min = minf(own_min, FacetAtlas.own_dist(fid, slot, pos.x, pos.y, pos.z))
	if own_min >= UPVECTOR_HEAL_NEAR_RIDGE:
		return {}
	# Authoritative check: is the soil cell under the feet actually junction-masked for the ACTIVE facet? The
	# same cell derivation the render/floor-scan junction path uses (effective_height's column top) — not a
	# re-invented probe.
	var xi := int(floor(pos.x))
	var zi := int(floor(pos.z))
	var yi := effective_height(xi, zi)
	if not bool(FacetAtlas.cell_seam_state(fid, xi, yi, zi)["air"]):
		return {}                                         # the soil is ours here — no strip, nothing to heal
	# The facet_of_dir classifier oracle names the true owner (also correct at a 3-facet corner diagonal).
	var w := FacetAtlas.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	var to := FacetAtlas.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	if to < 0 or to == fid:
		return {}
	var np := FacetAtlas.reframe_position64(fid, to, pos.x, pos.y, pos.z)
	# Accept only under the SAME corner-wall bound `_corner_commit` already uses — never place the player past
	# the −3 ridge wall. A rejection here just defers (the far ring still draws, the floor still carries them —
	# measured 0 corner-deferral tilt occurrences, §1.3 P2).
	var best := INF
	for bslot in 4:
		best = minf(best, FacetAtlas.own_dist(to, bslot, np[0], np[1], np[2]))
	if best < -(FACET_CROSS_HYST + FACET_CORNER_SLACK):
		return {}
	return _commit_facet_change(fid, to, np, -1)

## COSMOS FALL-THROUGH FIX (FP_DESCENT_FACET_RESYNC) — the GENERAL descent facet resync. A fast/high flight over a FAR
## region drifts the true sub-camera facet many facets away from the active facet while adjacent crossings are cooldown/
## containment-deferred and the high-flyer pool freeze (_pool_off_surface) deliberately suppresses re-designation — so the
## active facet LAGS. On a genuine (non-flying) descent the floor MUST be the real surface, but floor_under / surface_y
## evaluate the player's column against the STALE facet's piecewise-FLAT datum plane — extended far past its ridge domain
## that flat plane sinks hundreds of blocks below the sphere (the live surface_y ≈ −28 at a far spot with trees). This
## redesignates the active facet DIRECTLY onto the true facet_of_dir owner (the _alt_reentry_restore path — one O(1)
## _commit_facet_change, position/velocity-continuous via the returned reframe + the _heal_frame_desync invariant), so
## floor_under / surface_y read the owner's REAL surface. Guard: NON-ADJACENT owner only — an adjacent flip is the domain
## of maybe_cross_facet's −HYST/cooldown/containment hysteresis (never fought → normal walking is byte-identical). Returns
## the crossing dict (Player.apply_reframe consumes it) or {} (no resync). Off-flag / not-faceted ⇒ the guard returns {}.
func resync_subcamera_facet(player_pos: Vector3) -> Dictionary:
	if not (CubeSphere.FACETED and CubeSphere.FP_DESCENT_FACET_RESYNC):
		return {}
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return {}
	# The player's active-lattice position → planet-absolute direction → the TRUE sub-camera facet (the exact
	# high-flyer-drift computation _pool_off_surface already trusts). The lattice↔world map is frame-consistent by
	# the crossing invariant, so this is the real owner no matter how stale the active facet has become.
	var w := FacetAtlas.lattice_to_world64(fid, player_pos.x, player_pos.y, player_pos.z)
	var to := FacetAtlas.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	if to < 0 or to == fid:
		return {}
	# ADJACENT owner ⇒ defer to maybe_cross_facet (its hysteresis owns seam crossings so a −0.1 ridge-jitter flip can
	# never double-fire). Only a NON-ADJACENT owner (drifted ≥ 2 facets — unreachable by the adjacent-only seam march,
	# so unambiguously a stale-facet desync, never a normal walk step) is resynced here.
	for slot in 4:
		if FacetAtlas.seam_neighbour(fid, slot) == to:
			return {}
	var np: Array = FacetAtlas.reframe_position64(fid, to, player_pos.x, player_pos.y, player_pos.z)
	_alt_redesignate_count += 1
	print("[WorldManager] descent facet resync: redesignate %d -> %d (sub-camera facet, non-adjacent desync)" % [fid, to])
	return _commit_facet_change(fid, to, np, -1)

## COSMOS FP-FIXED-FRAME §2.2 / FP-M1c — the committed facet-change bookkeeping, shared by a normal seam crossing
## (maybe_cross_facet) and the R3 re-entry restore (_alt_reentry_restore). `to` is the destination facet, `np` the
## f64 reframed player landing (FacetAtlas.reframe_position64), `slot` the crossed seam slot (-1 for a re-entry
## restore — a direct facet_of_dir jump, not a seam march). Returns the `{crossed,…}` dict the player consumes via
## apply_reframe. This is the ONLY place the active facet flips + the near field re-designates. Byte-identical to the
## shipped inline crossing (a pure extract-method refactor; every path/instrumentation line is unchanged).
func _commit_facet_change(fid: int, to: int, np: Array, slot: int) -> Dictionary:
	var ex := FacetAtlas.crossing_basis(fid, to) * Vector3(1.0, 0.0, 0.0)   # A's +X in B-lattice → twist
	var yaw_delta := atan2(ex.z, ex.x)
	# A1 CROSSING INSTRUMENTATION (#114): time the whole committed crossing + its phases (rebuild-window,
	# redesignate, far-ring). Only runs once a crossing actually commits (this is the crossing path), so it
	# adds no per-frame cost; the record is published event-driven by RemoteBridge (see take_crossing_events).
	var _cross_t0 := Time.get_ticks_usec()
	var _rebuild_us := 0
	var _redesig_us := 0
	var _far_us := 0
	TerrainConfig.set_active_facet(to)
	# FP-M1a (§6.2): the overlay `_edits`/`_meta` are (fid, cell)-GLOBAL — untouched and now correct in
	# B's frame WITHOUT migration (an A-edit stays keyed to A; a B-edit resolves in B). But the WINDOW-keyed
	# PERF indices (`_edit_columns`/`_placed_top`) are in the OLD active lattice, so re-derive them for B by
	# filtering `fid == B` (the collider's fast-path gate stays exact across the crossing).
	var _rebuild_t0 := Time.get_ticks_usec()
	_rebuild_window_indices()
	_rebuild_us = Time.get_ticks_usec() - _rebuild_t0
	# The EDITABLE facet swaps to B. FP-M1c (pool ON): re-designation -- the pool already holds B, so a single
	# PlanetRoot transform swap + view rebalance makes B active and A a rotated neighbour, no teardown. Pool
	# OFF (FP-S1 fallback below): the old set_facet teardown + M4 cover restream. Far ring re-placed either way.
	var redesignated := false
	var _redesig_t0 := Time.get_ticks_usec()
	if CubeSphere.FP_M1_POOL and _module_world != null and _module_world.has_method("redesignate"):
		redesignated = bool(_module_world.call("redesignate", to))
		if not redesignated:
			# POOL-MISS (destination not pre-warmed): `to` is ALWAYS a seam-neighbour of the active facet, so spawn
			# it NOW (milliseconds) then re-designate -- still a HIT, no teardown. Track the miss (gate 0 in a walk).
			_pool_miss_count += 1
			if _module_world.has_method("pool_spawn") and bool(_module_world.call("pool_spawn", to)):
				redesignated = bool(_module_world.call("redesignate", to))
			if not redesignated and _module_world.has_method("pool_reset"):
				# Pathological (neighbour cap hit): rebuild the pool fresh on `to` -- degraded but consistent + never
				# blank. NOT the FP-S1 set_facet path.
				redesignated = bool(_module_world.call("pool_reset", to))
	_redesig_us = Time.get_ticks_usec() - _redesig_t0
	if redesignated:
		# FP_NB_WELD W3 (§3.3): the OLD active (`fid`) is now a widened band neighbour of `to` with its near field ALREADY
		# fully meshed — SEED its exclusion latch so its far cover tile never pops IN over the real blocky ground for the
		# post-crossing window (dead-probe: forever; welded probe: until the next successful probe). Seeded here, AFTER the
		# redesignate commit + BEFORE the ring sync below, so the SAME tick excludes it (two-phase safe; transforms untouched).
		# Flag-off ⇒ never seeded ⇒ shipped (a stale entry, were one somehow present, is cleared next pool pass, §z1hybrid).
		if CubeSphere.FP_NB_WELD and fid != to:
			_nb_excl_latch[fid] = true
		# FP-M1c: RE-DESIGNATION crossing -- ONE PlanetRoot transform write + view rebalance inside redesignate(),
		# NO teardown/restream/new generator. The old active field persists rotated (no removed frame). Re-place
		# the far ring + refresh its live-pool exclusion (deferred/rigid; no synchronous regen).
		var _far_t0 := Time.get_ticks_usec()
		if _facet_ring != null:
			_facet_ring.set_active(to)
			_facet_ring_sync_exclusion()
		if _skin != null:
			_skin.call("set_active", to)
		if _block_lod != null:
			_block_lod.rebuild(to)           # COSMOS BLOCK-LOD P1: re-stream the L1 band (active ∪ ridge-1) on crossing
		if _block_lod_ladder != null:
			_block_lod_ladder.rebuild(to)    # COSMOS BLOCK-LOD P2: re-assign + re-stream the L2..L4 ladder on crossing
		if _block_lod_global != null:
			_block_lod_global.rebuild(to)    # COSMOS BLOCK-LOD P2: re-mesh the near L5 cap around the new active facet
		if _block_lod_orbit != null:
			_block_lod_orbit.rebuild(to)     # COSMOS PLANET-LOD-CONFIG P0: re-centre the orbit disc on the new active facet
		_far_us = Time.get_ticks_usec() - _far_t0
	else:
		# flag-OFF path only: the FP-S1 set_facet teardown (restream via the M4 cover). Byte-identical to today
		# when FP_M1_POOL is off; unreachable under the pool (redesignate/spawn/reset always succeed).
		if _module_world != null and _module_world.has_method("set_facet"):
			var old_mod_pos: Vector3 = _module_world.position
			_module_world.call("set_facet", to, old_mod_pos)
		if _facet_ring != null:
			_facet_ring.set_active(to)
		if _skin != null:
			_skin.call("set_active", to)
		if _block_lod != null:
			_block_lod.rebuild(to)           # COSMOS BLOCK-LOD P1: re-stream the L1 band (active ∪ ridge-1) on crossing
		if _block_lod_ladder != null:
			_block_lod_ladder.rebuild(to)    # COSMOS BLOCK-LOD P2: re-assign + re-stream the L2..L4 ladder on crossing
		if _block_lod_global != null:
			_block_lod_global.rebuild(to)    # COSMOS BLOCK-LOD P2: re-mesh the near L5 cap around the new active facet
		if _block_lod_orbit != null:
			_block_lod_orbit.rebuild(to)     # COSMOS PLANET-LOD-CONFIG P0: re-centre the orbit disc on the new active facet
		_flip_settling = true
		_restream()
	# COSMOS FP-FIXED-FRAME §2.2 steps 4–8 (Phase 2 keystone) — the crossing is now pure O(1) bookkeeping.
	# redesignate() SKIPPED the PlanetRoot transform write (module_world, flag-gated), so NO
	# NOTIFICATION_TRANSFORM_CHANGED / per-mesh-block re-place fired (the 200–772 ms spike is gone). Instead we
	# re-place ONLY the ~10 NON-terrain children by flipping the ActiveFrame node from T_from to T_to:
	if _fixed_frame_on():
		# 4. ActiveFrame → T_to (the new active facet's TRUE absolute transform, folded through the re-anchor
		#    offset). Its children (player, collider, debris) keep their LATTICE locals; their globals follow to
		#    planet-absolute space. O(1) — never terrain. (Null-guard: _fixed_frame_on() is a pure flag read, but the
		#    ActiveFrame node is only built once _ready runs — a redesignation raced before that, e.g. a headless
		#    harness driving the crossing pre-_ready, must not crash; the live game always has it, so byte-identical.)
		if _active_frame != null:
			_active_frame.transform = _anchored(FacetAtlas.facet_transform(to))
		# 5. Debris compensation (§5 — also fixes the latent facet_atlas.gd:300 stranded-debris bug): the parent
		#    flip T_from→T_to would drag every VoxelBody child, so cancel it with Δ = T_to⁻¹·T_from on each body's
		#    LOCAL → its ABSOLUTE pose is preserved exactly. Velocities are physics-server-GLOBAL (untouched);
		#    sleepers keep their global pose → stay asleep. (The player is NOT compensated here — apply_reframe
		#    assigns its lattice-B local next; the collider is rebuilt below.)
		var cross_delta := FacetAtlas.crossing_transform(fid, to)
		for c in _frame_host().get_children():
			if c is VoxelBody:
				var vb := c as VoxelBody
				var was_sleeping := vb.sleeping   # preserve dormancy — a same-global re-place must not wake it
				vb.transform = cross_delta * vb.transform
				vb.sleeping = was_sleeping
		# 6. Resync the per-facet gravity volumes to the new live pool (§10 decision 2): `to`'s box already exists
		#    (it was a live neighbour) and is now re-stamped as the higher-priority active box; the old active stays
		#    a live neighbour with its own T_from-up box. Each debris keeps falling along ITS OWN facet's up.
		_sync_gravity_areas()
		# 8. GroundCollider: its live box shapes are in the OLD active lattice → now stale under the flipped frame.
		#    Force a fresh core-then-fill rebuild at the new active-lattice column (normal budget; still gated OFF
		#    entirely when no awake debris are near, exactly as today).
		if _ground != null:
			_ground.note_facet_crossing()
	_cross_cooldown = FACET_CROSS_COOLDOWN   # FP-S1(c): no re-fire for the next N ticks
	print("[WorldManager] facet cross %d -> %d (slot %d, %s)" % [fid, to, slot,
		"RE-DESIGNATION" if redesignated else "restream + far re-place"])
	# A1 CROSSING INSTRUMENTATION (#114): assemble + enqueue the per-crossing attribution record. The module
	# side (redesignate) measured the transform write + block count; drain it and combine with the crossing-total
	# split here. transform_ms is THE headline (the NOTIFICATION_TRANSFORM_CHANGED re-place spike). RemoteBridge
	# drains _crossing_events and publishes each as a distinct {"type":"crossing",…} JSON on the authed socket.
	var _cross_us := Time.get_ticks_usec() - _cross_t0
	var _rd: Dictionary = {}
	if _module_world != null and _module_world.has_method("take_last_redesignate"):
		_rd = _module_world.call("take_last_redesignate")
	var _rec := {
		"ev": "crossing",
		"from_fid": fid, "to_fid": to,
		"crossing_ms": snappedf(float(_cross_us) / 1000.0, 0.01),
		"transform_ms": snappedf(float(_rd.get("transform_us", 0)) / 1000.0, 0.01),
		"redesignate_ms": snappedf(float(_rd.get("redesignate_us", 0)) / 1000.0, 0.01),
		"rebuild_ms": snappedf(float(_rebuild_us) / 1000.0, 0.01),
		"far_ms": snappedf(float(_far_us) / 1000.0, 0.01),
		"redesig_call_ms": snappedf(float(_redesig_us) / 1000.0, 0.01),
		"blocks_replaced": int(_rd.get("blocks_replaced", 0)),
		"live_neighbours": int(_rd.get("live_neighbours", 0)),
		"lod_tiles": int(_rd.get("lod_tiles", 0)),
		"redesignated": redesignated,
	}
	_crossing_events.append(_rec)
	while _crossing_events.size() > CROSSING_EVENTS_MAX:
		_crossing_events.pop_front()   # NEVER-OOM: drop the oldest if no bridge is draining
	return {"crossed": true, "from": fid, "to": to,
		"new_pos": Vector3(float(np[0]), float(np[1]), float(np[2])), "yaw_delta": yaw_delta}

## COSMOS-PERF UNATTENDED R3 (FP_ALT_REGIME, §0-W3) — the ONE re-entry restore. On descent back below the ATMO_TOP
## gate the frozen active facet is stale (the ground track drifted while frozen), so redesignate directly onto the
## TRUE sub-camera facet (FacetAtlas.facet_of_dir of the player's world direction) — a single O(1) _commit_facet_change,
## NOT a slow seam-by-seam walk. The player pose is re-expressed by the returned crossing dict (apply_reframe) and the
## _heal_frame_desync invariant, so the restore is position/velocity-continuous. If the sub-camera facet already IS the
## frozen facet (a purely radial descent) nothing needs restoring — return {} and let the resumed pool + FP_LANDING_
## STREAM_KICK grow the near view for touchdown. Only reached under FP_ALT_REGIME, once, on the ORBITAL→SURFACE edge.
func _alt_reentry_restore(fid: int, player_pos: Vector3) -> Dictionary:
	var w := FacetAtlas.lattice_to_world64(fid, player_pos.x, player_pos.y, player_pos.z)
	var to := FacetAtlas.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	if to < 0 or to == fid:
		return {}   # already on the sub-camera facet — the frozen near field is correct; pool/stream resumes next tick
	_alt_redesignate_count += 1
	var np: Array = FacetAtlas.reframe_position64(fid, to, player_pos.x, player_pos.y, player_pos.z)
	print("[WorldManager] R3 re-entry restore: redesignate %d -> %d (sub-camera facet, alt gate)" % [fid, to])
	return _commit_facet_change(fid, to, np, -1)

## FP-M1c (§4.3): the neighbour-pool manager, run every physics tick from update_streaming (pool flag only).
## Spawn a facet whose own-side ridge distance is below D_WARM (nearest first), retire a pooled neighbour past
## D_RETIRE once it has lived >= MIN_LIVE_S, <=1 spawn AND <=1 retire per SPAWN_INTERVAL_S, hard cap 1 active +
## MAX_NEIGHBOURS. EDGE neighbours only (§8 -- the diagonal is FP-M1d). On any change it refreshes the far ring.
## RENDER-SIMPLIFY (docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §1) — the single near-LOD predicate. FP_NO_NEAR_LOD is the
## logical inverse of FP_M2_LOD, so every LOD *creation/policy* read routes through this helper: with FP_NO_NEAR_LOD off
## it equals FP_M2_LOD exactly (byte-identical); with it on the whole FacetLodMesher stack is bypassed (mesher never
## created, promote-hold + _lod_promote_pass + far-ring LOD-merge self-disable). The passive lod_* generator/terrain
## accessors deliberately stay on raw FP_M2_LOD — a null mesher never calls them, and verify_fp_m2 reads them directly.
func _near_lod_on() -> bool:
	return CubeSphere.FP_M2_LOD and not CubeSphere.FP_NO_NEAR_LOD

## FP_NB_FULLRES (§2) — the effective enable: the flag, AND the near view has settled (the fresh-load window stays
## Phase-A's — widening never competes with the initial reveal), AND we are on-surface (off-surface freezes the pool,
## §2.1). Off the flag → always false ⇒ every widened branch below is inert (byte-identical to shipped FP-M2d).
func nb_fullres_on(off_surface: bool) -> bool:
	return CubeSphere.FP_NB_FULLRES and _nb_settled and not off_surface

## FP_NB_FULLRES (§2.1) — the effective live-neighbour cap: the full 4 edges under FULLRES, else the shipped FP2_LIVE_CAP
## (1 imminent + 1 corner-second). POOL_MAX_NEIGHBOURS (4) is the geometric ceiling either way (asserted by G-M1-POOL).
func _z1_live_cap(fullres: bool) -> int:
	return CubeSphere.POOL_MAX_NEIGHBOURS if fullres else CubeSphere.FP2_LIVE_CAP

## FP_NB_FULLRES (§2.5, CORRECTION 1) — the ledger's MEASURED byte reading: engine-wide resident voxel-data bytes
## (VoxelEngine.get_stats().memory_pools.voxel_used, via the module's cached singleton) + the WASM static heap
## (OS.get_static_memory_usage(), the same reading G-M1-MEM uses). Both are real counters — no estimates. The static-heap
## term captures meshes/nodes/everything; the voxel_used term captures the data-block pool the static reading may not.
func _nb_measured_bytes() -> int:
	var voxel_used := 0
	if _module_world != null and _module_world.has_method("nb_voxel_used_bytes"):
		voxel_used = int(_module_world.call("nb_voxel_used_bytes"))
	return voxel_used + int(OS.get_static_memory_usage())

## FP_NB_FULLRES (§2 / §2.5) — latch `_nb_settled` the first time the near view is meshed, and snapshot the measured
## byte baseline B0 at that instant (BEFORE any widened spawn). The ledger enforces a GROWTH budget over B0 (§2.5); it
## re-snapshots whenever the widened pool is empty (drift honesty). No-op once settled + snapped. Flag-off → never
## called (guarded by FP_NB_FULLRES at the caller), so `_nb_settled` stays false ⇒ nb_fullres_on() stays false.
func _nb_settle_latch(player_pos: Vector3) -> void:
	if not _nb_settled:
		if initial_view_meshed(player_pos):
			_nb_settled = true
			_nb_b0_bytes = _nb_measured_bytes()
	elif _nb_b0_bytes < 0:
		_nb_b0_bytes = _nb_measured_bytes()

func _manage_facet_pool(player_pos: Vector3) -> void:
	if not _module_world.has_method("pool_spawn"):
		return
	var active := TerrainConfig.active_facet()
	if active < 0:
		return
	if CubeSphere.FP_NB_FULLRES:
		_nb_settle_latch(player_pos)                 # §2: latch settled + snapshot the measured byte baseline B0
	# Own-side ridge distance per EDGE neighbour (nearest slot wins). The diagonal is never a seam_neighbour, so it
	# never enters `want` → never live (Z1-hybrid §3.2 "the diagonal facet is never live"). Shared with both policies.
	var want := {}
	for slot in 4:
		var nb: int = FacetAtlas.seam_neighbour(active, slot)
		if nb < 0 or nb == active:
			continue
		var d := FacetAtlas.own_dist(active, slot, player_pos.x, player_pos.y, player_pos.z)
		if not want.has(nb) or d < float(want[nb]):
			want[nb] = d
	var changed := false
	if CubeSphere.FP_M2_LOD:
		# RENDER-SIMPLIFY §2.2: keep the Z1-hybrid pool policy (its imminent-commit machinery drives the seamless
		# crossing, capped at FP2_LIVE_CAP) even under FP_NO_NEAR_LOD — _near_lod_on() gates only the mesher SIDE-EFFECTS.
		changed = _manage_pool_z1hybrid(active, player_pos, want)
		if _near_lod_on():
			_lod_promote_pass(player_pos)            # evict held LOD covers whose live seam band has meshed (§9.1); no held covers under FP_NO_NEAR_LOD (far-ring quad is the cover)
	else:
		changed = _manage_pool_fp1c(want)            # shipped FP-M1c policy, byte-identical with the flag off
	if changed:
		_facet_ring_sync_exclusion()

## FP-M1c pool policy (shipped, unchanged) — 1 nearest neighbour under D_WARM, up to POOL_MAX_NEIGHBOURS, retire past
## D_RETIRE (+ MIN_LIVE_S), ≤1 spawn + ≤1 retire per SPAWN_INTERVAL_S. Reached only with FP_M2_LOD OFF. Returns `changed`.
func _manage_pool_fp1c(want: Dictionary) -> bool:
	var now := Time.get_ticks_msec()
	var interval_ms := int(CubeSphere.POOL_SPAWN_INTERVAL_S * 1000.0)
	var changed := false
	if now - _last_pool_spawn_ms >= interval_ms:
		var best := -1
		var best_d := CubeSphere.POOL_D_WARM
		for nb in want.keys():
			var d: float = want[nb]
			if d < best_d and not bool(_module_world.call("pool_has", nb)):
				best = nb; best_d = d
		if best >= 0 and int(_module_world.call("pool_neighbour_count")) < CubeSphere.POOL_MAX_NEIGHBOURS:
			if bool(_module_world.call("pool_spawn", best)):
				_last_pool_spawn_ms = now
				changed = true
	if now - _last_pool_retire_ms >= interval_ms:
		for nb in (_module_world.call("pool_neighbour_fids") as Array):
			var d: float = want.get(nb, 1.0e30)
			if d > CubeSphere.POOL_D_RETIRE and float(_module_world.call("pool_age_s", nb)) >= CubeSphere.POOL_MIN_LIVE_S:
				if bool(_module_world.call("pool_retire", nb)):
					_last_pool_retire_ms = now
					changed = true
					break
	return changed

## FP-M2d (§3.2) — the Z1-hybrid pool policy. Steady state = 1 active + 1 LIVE imminent neighbour (+ 1 corner-second when
## a 2nd ridge is within POOL_D_WARM2); every OTHER non-active facet is a FacetLodMesher LOD mesh, not a live terrain —
## the throughput win. Live PROMOTES are gated on the load controller (promote_admitted() + not backlog_gated(), §6.5.3.4)
## and on the off-surface freeze (high flyer, risk #6). Non-target live neighbours retire (demote → LOD via the far-ring
## quad, then rebuilt). ≤1 spawn + ≤1 retire per SPAWN_INTERVAL_S. Returns `changed` (whether the far ring needs a resync).
func _manage_pool_z1hybrid(active: int, player_pos: Vector3, want: Dictionary) -> bool:
	var live_now: Array = (_module_world.call("pool_neighbour_fids") as Array)
	var off_surface := _pool_off_surface(active, player_pos)
	# FP_NB_FULLRES (§2): under the flag (settled + on-surface) the selector targets ALL 4 edges (nearest-first tail) and
	# the live cap widens to POOL_MAX_NEIGHBOURS; off the flag `fullres` is false ⇒ every widened branch is inert (shipped).
	var fullres := nb_fullres_on(off_surface)
	_nb_fullres_active = fullres
	# CROSSING-FASTGEN obs-2 fix (3): pass the measured player speed so the imminent-select D_WARM shell leads with
	# velocity (vel_lead ≡ 0 with FP_VEL_PREDICT off → the shell is exactly POOL_D_WARM, byte-identical).
	var targets := z1_live_targets(want, off_surface, live_now, _player_speed, fullres)
	# FP_NB_FULLRES (§2.4): maintain the band-conditional far-ring exclusion latch — probe ≤1 live neighbour/tick for its
	# seam band, clear geometrically past NB_EXCL_RELEASE / on retire. Inert off the flag (keeps `_nb_excl_latch` empty).
	var latch_changed := false
	if fullres:
		var lc := _nb_update_excl_latch(live_now, want, player_pos)
		if CubeSphere.FP_NB_WELD:
			latch_changed = lc                       # W2: a latch set/clear must re-sync the far ring THIS tick (not the 0.5s throttle)
	elif not _nb_excl_latch.is_empty():
		_nb_excl_latch.clear()                       # flag flipped off / went off-surface → drop stale latches
	# CONTROLLER-FIX §P3c/§P3d: publish the imminent-ridge fid (targets[0], the incumbent-hysteresis winner) to the module
	# so its pool-ramp slot is pace-floored, its LOD stays budgeted through relief mode, and demote never coarsens it.
	_nb_imminent_fid = int(targets[0]) if targets.size() > 0 else -1   # FP_NB_FULLRES (§2.4): the band-conditional exclusion reads this outside the pool pass
	if _module_world != null and _module_world.has_method("set_imminent_fid"):
		var imm_fid: int = int(targets[0]) if targets.size() > 0 else -1
		# CROSSING-JERKINESS FIX: mark the imminent COMMITTED once its ridge is within POOL_D_COMMIT (the same geometric
		# gate promote_admit_imminent uses) so the module ramps it to full res at FULL pace before the seam, converting
		# the post-crossing 96→128 fill burst into an approach-spread trickle. CROSSING-FASTGEN obs-2 fix (3): the commit
		# distance gains a speed-proportional lead (vel_lead ≡ 0 with FP_VEL_PREDICT off → byte-identical) so a fast
		# player commits — hence ramps to full pace — EARLIER, giving the extra annulus more approach time to spread.
		var imm_committed: bool = imm_fid >= 0 and float(want.get(imm_fid, 1.0e30)) < CubeSphere.POOL_D_COMMIT + CubeSphere.vel_lead(_player_speed)
		_module_world.call("set_imminent_fid", imm_fid, imm_committed)
	var now := Time.get_ticks_msec()
	var interval_ms := int(CubeSphere.POOL_SPAWN_INTERVAL_S * 1000.0)
	var changed := false
	var live_cap := _z1_live_cap(fullres)
	# FP_NB_FULLRES (§2.5): the MEASURED-byte growth ledger (NEVER-OOM). `admit_widened` gates every NON-imminent spawn on
	# growth + NB_SPAWN_EST <= NB_POOL_BYTES_CAP; a breach latches `_nb_breached` (freeze non-imminent grows now, LRU/
	# farthest retire in the retire block), cleared only below cap − NB_BYTES_REHYST (hysteresis). The imminent keeps its
	# shipped path (the crossing invariant, cap-2-safe today). admit_widened ≡ true off the flag (byte-identical).
	var admit_widened := true
	if fullres:
		admit_widened = _nb_ledger_admit()
		if _nb_breached and _module_world.has_method("nb_freeze_grows"):
			_module_world.call("nb_freeze_grows")           # breach ladder step 2: freeze non-imminent grows
	# SPAWN (promote LOD → live): the highest-priority target not yet live, iff the controller admits it AND we are below
	# the Z1 live cap. One spawn per SPAWN_INTERVAL_S (amortized). W1 — targets[0] is the IMMINENT ridge (the one we are
	# committed to crossing); it is EXEMPT from the raw vox_gen backlog gate (while walking vox_gen naturally sits
	# 1500-2800, which would otherwise suppress the crossing promote → a silent fall-back to spawn-at-cross + a pool-miss).
	# It still needs sustained frame HEADROOM (promote_admit_imminent). The 2nd/corner target keeps the FULL backlog gate
	# — the feed-forward throttle applies to that EXTRA generation volume, and its view-ramp pace is throttled regardless.
	if now - _last_pool_spawn_ms >= interval_ms:
		# FP_NB_FULLRES (§2.2): imminent-priority SAME-TICK eviction — if the crossing target (targets[0]) is not yet live
		# and the widened pool is at the cap, retire the farthest NON-target live neighbour immediately (bypassing the
		# retire interval; MIN_LIVE_S still honored) so the imminent always finds a slot (no post-crossing pool-miss).
		if fullres and targets.size() > 0 and not bool(_module_world.call("pool_has", int(targets[0]))) \
				and int(_module_world.call("pool_neighbour_count")) >= live_cap:
			var ev := _nb_farthest_retirable(live_now, targets, want, true, -1.0)
			if ev >= 0 and bool(_module_world.call("pool_retire", ev)):
				live_now.erase(ev)
				_nb_excl_latch.erase(ev)
				changed = true
		for idx in range(targets.size()):
			var t: int = int(targets[idx])
			if bool(_module_world.call("pool_has", t)):
				continue
			if int(_module_world.call("pool_neighbour_count")) >= live_cap:
				break
			var admitted: bool = promote_admit_imminent(_load_ctrl, float(want.get(t, 1.0e30)), _player_speed) if idx == 0 else promote_admit(_load_ctrl)
			if idx > 0 and fullres and not admit_widened:
				admitted = false                             # ledger breach ladder step 1: refuse further widened spawns
			if not admitted:
				continue
			if bool(_module_world.call("pool_spawn", t)):       # module on_promote() HOLDS t's LOD cover (no gap, §9.1)
				_last_pool_spawn_ms = now
				# RENDER-SIMPLIFY §2.2: the promote-HOLD handshake self-disables when the mesher is null (pool_spawn
				# null-guards on_promote), so this bookkeeping is vestigial under FP_NO_NEAR_LOD — keep the map empty so
				# _lod_promote_pass's `_promote_pending.is_empty()` early-out stays free.
				if _near_lod_on():
					_promote_pending[t] = now                    # track → evict the held cover on seam-band-meshed
				changed = true
				break
	# RETIRE (demote live → LOD): a live neighbour that is no longer a target and has walked past D_RETIRE (hysteresis),
	# once it has lived ≥ MIN_LIVE_S. pool_retire() re-covers it as an LOD mesh (notify_pool_changed); the far-ring quad
	# bridges the brief rebuild window. One retire per SPAWN_INTERVAL_S.
	#
	# ACCEPTED v1 RESIDUAL (§9.2 build-first-demote, decisions ledger #9): the geometric retire frees the live terrain
	# BEFORE its LOD cover is built — the far-ring quad covers the gap, but its exclusion re-emit is deferred/budgeted,
	# so under SUSTAINED backlog-gating there is a brief coarse-flash / possible seam gap for a few frames. A true
	# build-first-demote requires the mesher to build an LOD cover for a still-LIVE facet, which the mesher deliberately
	# forbids (request()/_recompute_wants exclude pool facets) — a non-trivial new demote-build path + gate, deferred to
	# a follow-up. The W1/W10 controller fixes shrink the trigger (retire happens later / the promote holds longer).
	if now - _last_pool_retire_ms >= interval_ms:
		var retire_fid := -1
		if fullres:
			# FP_NB_FULLRES (§2.2): FARTHEST-first — the most useless facet frees its slot first (post-crossing the far-side
			# neighbours + old active retire nearest-last). Distance-retire self-disables for edge TARGETS (they stay live),
			# so this fires only on facets that LEFT the want-set past D_RETIRE (the crossing-rebalance path).
			retire_fid = _nb_farthest_retirable(live_now, targets, want, true, CubeSphere.POOL_D_RETIRE)
			# breach ladder step 3: still over the measured budget → shed the farthest NON-imminent live neighbour, even a
			# band target (NEVER-OOM outranks the seam cover). Re-admission is gated below cap − REHYST (no thrash).
			if retire_fid < 0 and _nb_breached:
				retire_fid = _nb_farthest_retirable(live_now, targets, want, false, -1.0)
		else:
			for nb in live_now:
				if targets.has(nb):
					continue
				var d: float = want.get(nb, 1.0e30)
				if d > CubeSphere.POOL_D_RETIRE and float(_module_world.call("pool_age_s", nb)) >= CubeSphere.POOL_MIN_LIVE_S:
					retire_fid = int(nb)
					break
		if retire_fid >= 0 and bool(_module_world.call("pool_retire", retire_fid)):
			_last_pool_retire_ms = now
			_nb_excl_latch.erase(retire_fid)
			# C4: do NOT erase _promote_pending here — retire alone would leave the mesher's promote-HOLD set
			# (on_promote) forever, PINNING the held LOD mesh in the cache (no idle/LRU path frees it). Instead let
			# THIS tick's _lod_promote_pass see `not pool_has(nb)` → lod_end_promote(nb) → lift the hold → erase.
			changed = true
	return changed or latch_changed                  # W2: fold in the FP_NB_WELD latch flip (byte-off: latch_changed ≡ false)

## FP_NB_FULLRES (§2.5) — the measured-byte growth-ledger admission. Returns whether a NEW non-imminent widened spawn is
## admitted, and maintains `_nb_breached` with cap/rehyst hysteresis. Growth = (voxel_used + static heap) − B0 (measured
## counters only, §1.3 CORRECTION 1). Over the cap (or above the absolute static-heap backstop) latches breach; below
## cap − REHYST clears it. B0 re-snapshots when the widened pool is empty (drift honesty — foreign growth then can't
## permanently poison the budget). Static so a future gate could drive it; here it reads live module + OS counters.
func _nb_ledger_admit() -> bool:
	if _nb_b0_bytes < 0:
		return true
	if int(_module_world.call("pool_neighbour_count")) == 0:
		_nb_b0_bytes = _nb_measured_bytes()          # empty pool → re-baseline; nothing to attribute NB growth to
		_nb_breached = false
		return true
	var growth := _nb_measured_bytes() - _nb_b0_bytes
	var over := growth + CubeSphere.NB_SPAWN_EST > CubeSphere.NB_POOL_BYTES_CAP \
		or int(OS.get_static_memory_usage()) > CubeSphere.NB_ABS_HEAP_MB * 1048576
	if over:
		_nb_breached = true
	elif growth < CubeSphere.NB_POOL_BYTES_CAP - CubeSphere.NB_BYTES_REHYST:
		_nb_breached = false
	return not _nb_breached

## FP_NB_FULLRES (§2.2) — the FARTHEST retirable live neighbour: max own-side ridge distance among live neighbours,
## never the imminent, honoring MIN_LIVE_S. `respect_targets` skips current targets (distance-retire + same-tick
## eviction of non-targets); false lets a band target be shed (breach ladder). `min_d` is the distance floor a candidate
## must EXCEED (POOL_D_RETIRE for the geometric retire; −1 = any, for breach/eviction). −1 return when none qualifies.
func _nb_farthest_retirable(live_now: Array, targets: Array, want: Dictionary, respect_targets: bool, min_d: float) -> int:
	var best := -1
	var best_d := min_d
	for nb in live_now:
		if int(nb) == _nb_imminent_fid:
			continue
		if respect_targets and targets.has(nb):
			continue
		if float(_module_world.call("pool_age_s", nb)) < CubeSphere.POOL_MIN_LIVE_S:
			continue
		var d: float = want.get(nb, 1.0e30)
		if d > best_d:
			best = int(nb)
			best_d = d
	return best

## FP_NB_FULLRES (§2.4) — maintain the band-conditional far-ring exclusion latch. CLEAR (geometric, no probe): a fid no
## longer live, or whose ridge walked past NB_EXCL_RELEASE (the player left → its band unloads → the far tile must return).
## SET (≤1 probe/tick, the nearest un-latched live neighbour): its seam band is meshed near the player (pool_seam_meshed).
## Keeps the far ring covering a live-but-empty neighbour until its band actually meshes (the cover-until-meshed contract).
func _nb_update_excl_latch(live_now: Array, want: Dictionary, player_pos: Vector3) -> bool:
	var changed := false                             # W2: report set/clear so _manage_pool_z1hybrid re-syncs the ring SAME-TICK
	for fid in _nb_excl_latch.keys():
		if not live_now.has(fid) or float(want.get(fid, 1.0e30)) > CubeSphere.NB_EXCL_RELEASE:
			_nb_excl_latch.erase(fid)
			changed = true
	var cand := -1
	var cand_d := 1.0e30
	for nb in live_now:
		if int(nb) == _nb_imminent_fid or _nb_excl_latch.has(nb):
			continue                                 # the imminent is excluded via _nb_excluded_neighbour regardless — don't waste the probe on it
		var d := float(want.get(nb, 1.0e30))
		if d < cand_d:
			cand = int(nb)
			cand_d = d
	# FP_NB_WELD W1: only probe inside the band's CERTAIN reach — the strip foot then sits ≤ NB_PROBE_RIDGE_MAX +
	# NB_PROBE_DEPTH (60) < the 64-block band, so a `true` is real evidence. Off-flag the gate is absent (shipped: probe at
	# any distance — harmless, the shipped box is dead anyway), preserving byte-off. Farther out the tile SHOULD cover (§3.1).
	var gate_ok := true
	if CubeSphere.FP_NB_WELD:
		gate_ok = cand_d < CubeSphere.NB_PROBE_RIDGE_MAX
	if cand >= 0 and gate_ok and bool(_module_world.call("pool_seam_meshed", cand, player_pos)):
		_nb_excl_latch[cand] = true
		changed = true
	return changed

## FP_NB_FULLRES (§2.4) — is live neighbour `nb` far-ring-EXCLUDED under the widened pool? Only when it is the imminent/
## committed crossing target (shipped cover-until-meshed) or its seam band has latched. A live-but-empty neighbour is NOT
## excluded → it keeps its far tile (no see-through hole). Shared by the far-ring exclusion and the skin candidate set.
func _nb_excluded_neighbour(nb: int) -> bool:
	return nb == _nb_imminent_fid or _nb_excl_latch.has(nb)

## FP-M2d (§3.2) — the PURE Z1-hybrid target selector (static so G-M2-POLICY drives it directly). Given each edge
## neighbour's own-side ridge distance `want[fid]`, the off-surface freeze flag, and the currently-live neighbour set,
## returns the fids that SHOULD be live terrains (0, 1, or 2). Rules: off-surface → [] (freeze). Else the imminent =
## the nearest ridge under D_WARM, BUT an already-live incumbent is kept unless a challenger beats it by POOL_SWITCH_MARGIN
## (anti-thrash). Plus a corner-second = the nearest OTHER ridge under POOL_D_WARM2, capped at FP2_LIVE_CAP. Every
## returned fid is present in `want` (edge-only), so a diagonal — never in `want` — can never be a live target.
## CROSSING-FASTGEN obs-2 fix (3): `speed` (blocks/s, default 0) widens the imminent-select shell by vel_lead(speed) so a
## fast player selects the crossing-target facet earlier. Default 0 + FP_VEL_PREDICT off ⇒ vel_lead ≡ 0 ⇒ shell is exactly
## POOL_D_WARM, byte-identical, and the headless gates (which pass 3 args) are unaffected. The corner-second D_WARM2 shell
## is deliberately NOT led — the extra corner volume stays gated on the tighter shipped shell (conservative, NEVER-OOM).
## FP_NB_FULLRES (§2.1): `fullres` grows ONE flag-gated tail — after the imminent, append every remaining edge in `want`
## nearest-first (up to POOL_MAX_NEIGHBOURS) instead of the single corner-second. Default false ⇒ byte-identical shipped
## output (the corner-second branch), so G-M2-POLICY / G-SP-NB-OFF stay green and the static gate drives both directly.
static func z1_live_targets(want: Dictionary, off_surface: bool, live_now: Array, speed: float = 0.0, fullres: bool = false) -> Array:
	var out: Array = []
	if off_surface:
		return out
	var warm := CubeSphere.POOL_D_WARM + CubeSphere.vel_lead(speed)
	var arr: Array = []
	for nb in want.keys():
		if float(want[nb]) < warm:
			arr.append([float(want[nb]), int(nb)])
	if arr.is_empty():
		return out
	arr.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	# imminent (with incumbent hysteresis): the nearest, unless a live incumbent is within POOL_SWITCH_MARGIN of it.
	var imm := int(arr[0][1])
	var imm_d := float(arr[0][0])
	var inc := -1
	var inc_d := 1.0e30
	for c in arr:
		if live_now.has(int(c[1])) and float(c[0]) < inc_d:
			inc = int(c[1]); inc_d = float(c[0])
	if inc >= 0 and imm != inc and imm_d > inc_d - CubeSphere.POOL_SWITCH_MARGIN:
		imm = inc; imm_d = inc_d                              # challenger did not beat the incumbent by the margin — hold
	out.append(imm)
	if fullres:
		# FP_NB_FULLRES (§2.1): the FULL-COVERAGE tail — every remaining edge of `want`, nearest-first (arr is sorted
		# ascending), up to POOL_MAX_NEIGHBOURS. No D_WARM2 shell gate: all 4 edges become targets so the seam see-through
		# closes on every side. Spawn PACING is unchanged (the caller still admits ≤1/interval through the full AIMD gate),
		# so this only changes HOW MANY facets may eventually hold a band, not how fast anything fills.
		for c in arr:
			if out.size() >= CubeSphere.POOL_MAX_NEIGHBOURS:
				break
			if int(c[1]) != imm:
				out.append(int(c[1]))
		return out
	# corner-second: the nearest OTHER ridge inside the tighter D_WARM2 shell, up to the live cap.
	for c in arr:
		if out.size() >= CubeSphere.FP2_LIVE_CAP:
			break
		if int(c[1]) != imm and float(c[0]) < CubeSphere.POOL_D_WARM2:
			out.append(int(c[1]))
			break
	return out

## FP-M2d (§6.5.3.4) — is a live-terrain promote admitted right now? Requires credit ≥ CTRL_PROMOTE_CREDIT sustained
## AND the vox_gen backlog gate open (promotions start only into real, drained headroom). null controller (flag-off /
## no source) → always admit (the shipped FP-M1c behaviour). Static so G-M2-POLICY asserts the backlog-gated denial.
static func promote_admit(ctrl) -> bool:
	if ctrl == null:
		return true
	return bool(ctrl.promote_admitted()) and not bool(ctrl.backlog_gated())

## FP-M2d (W1) + CONTROLLER-FIX §P3b — is the SINGLE imminent live-terrain promote admitted? The ridge the player is
## committed to crossing is EXEMPT from the raw vox_gen backlog gate (which naturally holds while walking, and would
## otherwise suppress the crossing promote → spawn-at-cross + a pool-miss). Two admit paths:
##  • polite (headroom): sustained frame headroom (promote_imminent_admitted) — used in the [D_COMMIT, D_WARM] band,
##    where the controller may defer the spawn to a headroom tick (frequently available under P1/P2 when the player pauses);
##  • committed (geometric): ridge_dist < POOL_D_COMMIT — the crossing is committed, the generation cost is no longer
##    optional, and pre-paying it now (≈6.7 s of lead even at run speed) strictly dominates paying it at the seam.
## A pinned-0 credit (the live starvation, §1) can no longer VETO the imminent live invariant (§3.2) — only pace WHEN it
## starts within the politeness window. null controller (flag-off / no source) → always admit (shipped FP-M1c). Static so
## G-M2-POLICY / G-M2-STARVE assert both the headroom path (out-of-commit distance) and the geometric commit at credit 0.
## CROSSING-FASTGEN obs-2 fix (3): `speed` (blocks/s, default 0) leads the geometric commit band by vel_lead(speed) so a
## fast player commits the crossing earlier. Default 0 + FP_VEL_PREDICT off ⇒ vel_lead ≡ 0 ⇒ the band is exactly
## POOL_D_COMMIT, byte-identical, and the G-M2 gates (which pass 2 args) are unaffected.
static func promote_admit_imminent(ctrl, ridge_dist: float, speed: float = 0.0) -> bool:
	if ctrl == null:
		return true
	return bool(ctrl.promote_imminent_admitted()) or ridge_dist < CubeSphere.POOL_D_COMMIT + CubeSphere.vel_lead(speed)

## FP-M2d (risk #6, §10) — off-surface spawn freeze: a HIGH FLYER (altitude above the active facet plane > OFFSURFACE_Y)
## whose radial direction has drifted over a DIFFERENT facet should not thrash the pool by skimming ridges. Returns true
## only when both hold. The player's active-facet-lattice position → planet-absolute direction → facet_of_dir classifier.
func _pool_off_surface(active: int, player_pos: Vector3) -> bool:
	if player_pos.y <= CubeSphere.OFFSURFACE_Y:
		return false
	var w := FacetAtlas.lattice_to_world64(active, player_pos.x, player_pos.y, player_pos.z)
	var rad_fid := FacetAtlas.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	return rad_fid != active

## FP-M2d (§9.1) — the promote-completion pass: for every in-flight live promote, drop the held LOD cover once the live
## terrain's seam-side band (nearest the player) has meshed — or after PROMOTE_EVICT_MAX_S (never pin double geometry).
## Dropping a facet that retired before its promote completed is handled first (it is no longer live).
func _lod_promote_pass(player_pos: Vector3) -> void:
	if _promote_pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	var done: Array = []
	for fid in _promote_pending.keys():
		if not bool(_module_world.call("pool_has", fid)):
			_module_world.call("lod_end_promote", fid)        # retired before completing — lift the hold, keep the LOD mesh
			done.append(fid)
			continue
		var meshed := bool(_module_world.call("pool_seam_meshed", fid, player_pos))
		# W10: dropping the held LOD cover over UN-meshed live terrain is a real see-through hole. Under backlog
		# starvation the seam may not mesh within PROMOTE_EVICT_MAX_S — EXTEND the timeout (×PROMOTE_EVICT_STARVE_MULT)
		# while the controller is starving the stream, so the cover holds until the live seam is really up. The hard-cap
		# escape stays (never pin double geometry forever) — it just becomes much longer under starvation.
		var cap_s := CubeSphere.PROMOTE_EVICT_MAX_S
		if _load_ctrl != null and bool(_load_ctrl.backlog_gated()):
			cap_s *= CubeSphere.PROMOTE_EVICT_STARVE_MULT
		var timed_out := now - int(_promote_pending[fid]) > int(cap_s * 1000.0)
		if meshed or timed_out:
			_module_world.call("lod_evict", fid)             # live full-res now covers the seam → drop the LOD overlap
			done.append(fid)
	for fid in done:
		_promote_pending.erase(fid)

## FP-M1c: refresh the FacetFarRing exclusion to the live pool's NEIGHBOUR fids (the active facet is excluded by
## the ring itself). Deferred rebuild (budgeted _process) so a spawn/retire/crossing never pays a synchronous regen.
func _facet_ring_sync_exclusion() -> void:
	if _facet_ring == null or _module_world == null or not _module_world.has_method("pool_neighbour_fids"):
		return
	if not _facet_ring.has_method("set_pool_excluded"):
		return
	# FP-M2b (§5.5): the ring's excluded set = live pool neighbours ∪ the facets whose LOD mesh is APPLIED, merged
	# into ONE deferred/budgeted set_pool_excluded (no synchronous ring regen). With FP_M2_LOD off lod_covered_fids
	# is [] → this reduces to the shipped FP-M1c pool-neighbour exclusion, byte-identical.
	var neigh: Array = (_module_world.call("pool_neighbour_fids") as Array)
	var excluded: Array = []
	if _nb_fullres_active:
		# FP_NB_FULLRES (§2.4 CORRECTION 2): BAND-CONDITIONAL exclusion. Under the widened pool a live neighbour is
		# excluded from the far ring ONLY when it is the imminent/committed crossing target (shipped cover-until-meshed via
		# the promote-HOLD) or its seam band has meshed (_nb_excl_latch). A live-but-EMPTY neighbour (player mid-facet, its
		# localized viewer out of reach) stays far-ring-COVERED → no see-through hole (the whole-facet binary exclusion,
		# applied the instant a neighbour went live, was the regression this fixes).
		for nb in neigh:
			if _nb_excluded_neighbour(int(nb)):
				excluded.append(nb)
	else:
		excluded = neigh.duplicate()
	# RENDER-SIMPLIFY §2.4: under FP_NO_NEAR_LOD there is no LOD cover, so the excluded set collapses to live pool
	# neighbours only — every ex-LOD facet then shows its far-ring quad. _near_lod_on() short-circuits the merge.
	if _near_lod_on() and _module_world.has_method("lod_covered_fids"):
		for f in (_module_world.call("lod_covered_fids") as Array):
			if not excluded.has(f):
				excluded.append(f)
	_facet_ring.set_pool_excluded(excluded)

## COSMOS SEAMLESS-SCALES C3: the facets the skin should cover — the active facet plus the live-pool
## neighbours (the front-hemisphere facets the near disc/annulus can reach). Mirrors the far ring's
## excluded set so the skin and the pool cover the same facets.
func _skin_candidate_fids() -> PackedInt32Array:
	var out := PackedInt32Array([TerrainConfig.active_facet()])
	if _module_world != null and _module_world.has_method("pool_neighbour_fids"):
		for f in (_module_world.call("pool_neighbour_fids") as Array):
			# FP_NB_FULLRES (§2.4): mirror the far-ring's band-conditional set — the skin covers a widened neighbour only
			# when the far ring also excludes it (imminent/band-meshed), so skin + far-ring + near stay one coherent cover.
			if _nb_fullres_active and not _nb_excluded_neighbour(int(f)):
				continue
			if not out.has(int(f)):
				out.append(int(f))
	return out

## FP-M1c gate accessor: the count of re-designation POOL-MISS fallbacks so far (must be ~0 in a normal walk).
func pool_miss_count() -> int:
	return _pool_miss_count

## FP-M2d M2e-WIRE hook (verify_fp_m2_soak §M2e-WIRE): the FacetLodMesher ledger snapshot (facets/tris/bytes/aprons/
## in-flight, forwarded from module_world.lod_stats() → mesher.stats()). {} without a pool-capable module / flag off, so
## the soak asserts the LOD caps hold throughout the walk (§11) alongside stream_load_credit() and the neighbour count.
func lod_stats() -> Dictionary:
	if _module_world != null and _module_world.has_method("lod_stats"):
		return _module_world.call("lod_stats")
	return {}

## FP-M1c gate accessor: is facet `fid` currently in this WorldManager's live pool? (module passthrough; false
## without a pool-capable module). Used by the end-to-end walk-soak gate to confirm the pool warmed before a crossing.
func facet_pool_has(fid: int) -> bool:
	return _module_world != null and _module_world.has_method("pool_has") and bool(_module_world.call("pool_has", fid))
func facet_pool_neighbour_count() -> int:
	return int(_module_world.call("pool_neighbour_count")) if (_module_world != null and _module_world.has_method("pool_neighbour_count")) else 0

## A1 CROSSING INSTRUMENTATION (#114): drain + return all per-crossing attribution records queued since the last call
## (FIFO, oldest first), clearing the queue. RemoteBridge polls this each frame and publishes each record as a
## distinct {"type":"crossing",…} JSON on the authed telemetry socket. Empty in normal play (a crossing is seconds
## apart); the queue only ever fills on committed faceted crossings, so this is a no-op when FACETED is off.
func take_crossing_events() -> Array:
	if _crossing_events.is_empty():
		return []
	var out := _crossing_events
	_crossing_events = []
	return out

## T2e (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): drain the FacetFarRing's per-rebuild build/swap timing records for the
## telemetry socket. Guarded for the non-faceted / fallback path (no ring) → always [] there. RemoteBridge publishes each
## as a distinct {"type":"farring",…} JSON line (same event-drain pattern as take_crossing_events); the record convicts
## or acquits the §2.2c zero-queue crossing stall (far-ring re-emit is the prime suspect).
func take_farring_events() -> Array:
	if _facet_ring == null or not _facet_ring.has_method("take_events"):
		return []
	return _facet_ring.take_events()

## COSMOS SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2): the planet centre in the current render
## frame (the far-ring placement translation), for the SN3 driver to derive the camera distance/altitude. No
## faceted ring (fallback / flat) ⇒ the origin. DEAD unless FP_SCALED_BODY is on (only main._process calls it).
func planet_render_centre() -> Vector3:
	if _facet_ring == null:
		return Vector3.ZERO
	return _facet_ring.render_centre()

## The planet's LIVE render placement (body-centred ABSOLUTE frame → scene): the FacetFarRing node's
## global_transform, which folds T_active⁻¹ / the fixed-frame anchor AND the SN3 scaled-body clamp (position +
## basis + scale). Anything built in the same absolute frame (the dev-nav overlay guides) rides this to sit ON
## the rendered planet. Identity when there is no faceted ring yet.
func planet_render_transform() -> Transform3D:
	if _facet_ring == null:
		return Transform3D.IDENTITY
	return _facet_ring.global_transform

## COSMOS SPACE-NAV SN3 (§5.2): apply the scaled-body distance clamp to the far ring for this frame. No-op when
## there is no faceted ring. Below D_ENGAGE this is byte-identical to the shipped placement (the clamp scale is
## exactly 1). Called per frame by main._process under FP_SCALED_BODY only.
func apply_scaled_body(cam: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.apply_scaled_placement(cam)

## COSMOS PLANET-LOD-CONFIG P0 (docs/COSMOS-PLANET-LOD-CONFIG-DESIGN.md §2): drive the crisp orbit megablock disc from
## this frame's camera. Recovers the ABSOLUTE sub-camera direction + distance-from-centre the SAME way the far ring's
## apply_camera_set does (the mesh is absolute planet coords under _placement_xform; the SN3 scale is screen-invariant
## so it never enters the direction/distance), feeds them to the orbit tier (engage/re-assign with hysteresis), then
## RETIRES the §2V skin on the far ring while the tier is engaged (swap, not overlay — frees the base map + kills the
## on-the-fly bake). No orbit node (flag off) ⇒ no-op ⇒ byte-identical. Called per frame by main._process under the flag.
func update_block_lod_orbit(cam: Vector3) -> void:
	if _block_lod_orbit == null or _facet_ring == null:
		return
	var base := _facet_ring.render_centre()          # the body centre in the RENDER frame (= _placement_xform().origin)
	var rel := cam - base                             # camera relative to the body centre, render frame
	var d := rel.length()
	var abs_rel := _facet_ring.transform.basis.inverse() * rel   # rotate the offset back into ABSOLUTE mesh space
	var u := abs_rel.normalized() if abs_rel.length() > 1.0e-6 else Vector3(0.0, 1.0, 0.0)
	var engaged: bool = _block_lod_orbit.set_camera(u, d)
	# §2V retire — but ONLY once the orbit mesh actually COVERS the disc (its first worker build has committed). Retiring
	# on the bare `engaged` flip would blank the skin during the seconds-scale worker fill (no skin + no blocks yet); by
	# gating on covered geometry the far ring keeps wearing §2V until the crisp megablocks are ready to overdraw it, so
	# the swap is a clean hand-off with no blank window. Below the swap (or before the fill lands) the skin stays lit.
	var retire := engaged and not _block_lod_orbit.covered_fids().is_empty()
	if retire != _orbit_skin_retired:
		_orbit_skin_retired = retire
		# Suppress the smooth skin on the far ring so the orbit megablocks own the disc (the far ring stays as the sunk
		# backstop — round silhouette + rim — but reads as the plain agreeing FarPalette, no blotch). Restore on descent.
		if _facet_ring.has_method("set_skin_active"):
			_facet_ring.set_skin_active(not retire)
		if _facet_tex != null and _facet_tex.has_method("set_frozen"):
			_facet_tex.set_frozen(retire)   # freeze §2V page bakes at orbit (no bake pop-in); resume on descent

## COSMOS-ORBITAL-SHELL S1/S2 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3/§4): drive the far ring's camera-radial
## emitted-set law + one-shot prewarm arming from this frame's camera (render frame). No faceted ring (fallback/
## flat) ⇒ no-op. Called per frame by main._process under (FP_SHELL_CAMERA_SET or FP_SHELL_PREWARM); independent
## of apply_scaled_body (separate flag/driver — the shell fix is standalone-correct below h ≈ 6.3 k without SN3).
func update_shell_camera_set(cam: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.apply_camera_set(cam)

## COSMOS-LOD-SKY L3 (SHELL_TERMINATOR_TINT): forward the current Sun direction to the far-ring shell tint shader.
## No-op with no faceted ring or the flag off (the setter self-guards) ⇒ byte-identical.
func set_far_ring_sun_dir(sun_dir: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_terminator_sun_dir(sun_dir)

## COSMOS ATMO-SKY A5 (FP_SHELL_ABSOLUTE): forward the current Sun direction into the far-ring shell v2 shader.
## No-op with no faceted ring or the flag off (the setter self-guards) ⇒ byte-identical.
func set_far_ring_shell_absolute(sun_dir: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_shell_absolute_sun_dir(sun_dir)
	# COSMOS BLOCK-LOD P1: the L1 rim ring shades by the SAME shell shade·tint law (radial normal) — feed it the same
	# Sun at the same frame so the megablocks day/night-match the far skin. No-op / byte-identical unless FP_BLOCK_LOD.
	if _block_lod != null:
		_block_lod.set_sun_dir(sun_dir)
	# COSMOS BLOCK-LOD P2: the ladder + global tiers shade by the SAME shell law — feed them the same Sun each frame.
	if _block_lod_ladder != null:
		_block_lod_ladder.set_sun_dir(sun_dir)
	if _block_lod_global != null:
		_block_lod_global.set_sun_dir(sun_dir)
	if _block_lod_orbit != null:
		_block_lod_orbit.set_sun_dir(sun_dir)
	# FP_FAR_TERMINATOR_WELD (docs/COSMOS-FAR-TERMINATOR-DESIGN.md §4.1): the SAME unconditional backstop as the
	# block-LOD fan-out above — FacetSkinTier's biased material had NO refresh path at all before this flag (built
	# once in setup(), never touched again). Feed it here too, at the SAME broad condition (FP_SHELL_ABSOLUTE OR
	# FP_SHADE_UNIFIED OR FP_NIGHT_TERRAIN_CENTRE, main.gd:307-308) so it can never freeze at the hardcoded seed
	# while the shell/block-LOD tiers track live time. `_skin.set_sun_dir` self-guards on the flag ⇒ byte-identical.
	if _skin != null and _skin.has_method("set_sun_dir"):
		_skin.call("set_sun_dir", sun_dir)

## docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2): forward the current Sun direction to the smooth-v2
## annulus's own material. No-op with no faceted ring / no smooth-v2 instance (the ring setter self-guards) ⇒
## byte-identical.
func set_smooth_v2_sun_dir(sun_dir: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_smooth_v2_sun_dir(sun_dir)

## docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md WS3 (task #99 G3): forward the current Sun direction to G3's own
## material. No-op with no faceted ring / no orbit-relief instance (the ring setter self-guards) ⇒ byte-identical.
func set_orbit_relief_sun_dir(sun_dir: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_orbit_relief_sun_dir(sun_dir)

## docs/COSMOS-FAR-TREES-DESIGN.md (P0): forward the current Sun direction + the live camera into the far-tree
## card tier each frame. No-op with no faceted ring (the ring setters self-guard) ⇒ byte-identical off.
func set_far_trees_sun_dir(sun_dir: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_far_trees_sun_dir(sun_dir)

func set_far_trees_camera(cam: Vector3) -> void:
	if _facet_ring != null:
		_facet_ring.set_far_trees_camera(cam)

## docs/COSMOS-FAR-TREES-DESIGN.md (P2 §5.5): true iff the player has an edit at (fid, cell) — the far-tree chop
## filter's predicate. Faceted (no chart) keys by FacetAtlas.edit_key(fid, cell) — a pure/O(1) `_edits.has`. Empty
## overlay / non-faceted-chart ⇒ false (no filter). Main-thread only (called from the far-trees rebuild).
func far_tree_chopped(fid: int, cell: Vector3i) -> bool:
	if _edits.is_empty() or _chart != null or not CubeSphere.FACETED:
		return false
	return _edits.has(FacetAtlas.edit_key(fid, cell))

# docs/COSMOS-FARTREE-CHOP-DESIGN.md §4.2 (FP_FT_SKIN_CHOP, task #137): the rung-3 far-skin chop snapshot.
var _skin_chop_memo: Dictionary = {}   # fid -> {rev:int, snap:Dictionary(Vector2i(lx,lz) -> post-chop top block id)}

## FP_FT_SKIN_CHOP: the far-skin edit snapshot for facet `fid` — {Vector2i(lx,lz) -> post-chop TOP BLOCK id} covering
## every column whose procedural tree is CHOPPED (trunk-base cell (bx, gy+1, bz) edited — EXACTLY far_tree_chopped's
## predicate above, so rung 3 flips with rungs 1/2 on the same edit). The bake's EDIT branch runs AHEAD of its TREE
## branch (all three _pbm_compute paths + C++ bake_far_tile, patch 0011), so these columns bake the bare-terrain
## index instead of the phantom canopy. Footprint = the tree's own G×G grid cell where TreeGen.top_decoration is
## non-air (a column only ever carries its OWN grid cell's tree — tree_block_at homes on the column's cell — so the
## footprint is exact and needs no canopy-radius or tile-boundary math). Value = TerrainConfig.top_block_id(...), the
## IDENTICAL call the bare-terrain bake branch classifies, so a chopped column bakes bit-equal to a treeless one.
## Memoized per (fid, edit_count()); {} when the flag is off / overlay empty / nothing chopped. Main-thread only —
## the baker freezes the result into per-slot arrays at bake dispatch (never live-read off-thread). `force` is the
## gate-forcing convention (verify_ft_skin_chop exercises the mechanism without a compile-time sed); every real
## caller passes no override ⇒ the compile const governs (byte-identical off).
func far_skin_edit_snap(fid: int, force := CubeSphere.FP_FT_SKIN_CHOP) -> Dictionary:
	if not force or _edits.is_empty() or _chart != null or not CubeSphere.FACETED:
		return {}
	var rev := edit_count()
	var memo: Dictionary = _skin_chop_memo.get(fid, {})
	if not memo.is_empty() and int(memo["rev"]) == rev:
		return memo["snap"]
	var snap := {}
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var seen := {}                                          # grid cell (gx,gz) -> true (dedupe per tree)
	# The R5 per-fid index gives this facet's edits in O(its edits); with the index flag off, fall back to a
	# full-overlay scan filtered by edit_key_fid (gates run flag-off; chop counts are tiny either way).
	var keys: Array = edits_for_fid(fid).keys() if CubeSphere.FP_EDIT_FID_INDEX else _edits.keys()
	for ek in keys:
		if not CubeSphere.FP_EDIT_FID_INDEX and FacetAtlas.edit_key_fid(int(ek)) != fid:
			continue
		var cell: Vector3i = FacetAtlas.edit_key_unpack(int(ek))[1]
		var gx := floori(float(cell.x) / float(TreeGen.G))
		var gz := floori(float(cell.z) / float(TreeGen.G))
		var gk := Vector2i(gx, gz)
		if seen.has(gk):
			continue
		seen[gk] = true
		var info := TreeGen.tree_info(gx, gz, ctx)
		if info.is_empty():
			continue
		var base: Vector3i = info["base"]
		if not _edits.has(FacetAtlas.edit_key(fid, Vector3i(base.x, base.y + 1, base.z))):
			continue                                        # tree present but not chopped
		for lx in range(gx * TreeGen.G, (gx + 1) * TreeGen.G):
			for lz in range(gz * TreeGen.G, (gz + 1) * TreeGen.G):
				if TreeGen.top_decoration(lx, lz, ctx) != BlockCatalog.AIR:
					var prof: Vector4 = TerrainConfig.facet_profile(fid, lx, lz)
					snap[Vector2i(lx, lz)] = TerrainConfig.top_block_id(int(prof.x), int(prof.y), prof.w, lx, lz)
	_skin_chop_memo[fid] = {"rev": rev, "snap": snap}
	return snap

## FP_FT_SKIN_CHOP: is `cell` (facet `fid` lattice) the trunk-base cell of its column's procedural tree? The O(1)
## chop-toggle detect the write/erase choke points use to invalidate the facet's baked far-skin tiles — building a
## house never fires it. Same cell law as far_tree_chopped's consumers: base + (0, 1, 0).
func _is_trunk_base_edit(fid: int, cell: Vector3i) -> bool:
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var info := TreeGen.tree_info(
		floori(float(cell.x) / float(TreeGen.G)), floori(float(cell.z) / float(TreeGen.G)), ctx)
	if info.is_empty():
		return false
	var base: Vector3i = info["base"]
	return cell == Vector3i(base.x, base.y + 1, base.z)

## docs/COSMOS-FARTREE-ALIGN-DESIGN.md (§5, FP_FAR_TREES_NEARCULL): the shared near-mesh-presence predicate bound to
## the module world — is facet `fid`'s NEAR voxel field actually meshed over the fid-lattice `box`? Tri-state
## (NearPresence.COVERED|NOT_COVERED|UNKNOWABLE). A null / fallback module world ⇒ UNKNOWABLE (the tier degrades to
## today's distance band). Pure read (is_area_meshed + the live view-band); no streaming/apply cost.
func far_tree_near_presence(fid: int, box: AABB) -> int:
	return NearPresence.covered(_module_world, fid, box)

## docs/COSMOS-STRUCTURES-DESIGN.md (P0, §7): the registered player structures (StructureTracker.registry) — the
## far-structure tier walks THIS, never the world. Empty with no tracker (FP_STRUCT_DETECT off) ⇒ the tier renders
## nothing (byte-identical). Each call returns fresh record dicts the tier snapshots.
func structure_registry() -> Array:
	return _structure_tracker.registry() if _structure_tracker != null else []

## docs/COSMOS-STRUCTURES-DESIGN.md (P0, §6.1): the decimator's cell sampler — the PLACED overlay material at
## (fid, cell), or 0 for air / non-placed. Reads the overlay DIRECTLY by (fid, cell) edit key (fid-agnostic, unlike
## block_id_at which assumes the active facet) so a far structure on any facet decimates; and it is placed-ONLY (the
## structure alone, no adjacent terrain slab). A dug placed cell reads air ⇒ damage shows in the far model for free.
func structure_cell_at(fid: int, cell: Vector3i) -> int:
	var v: int = _edits.get(FacetAtlas.edit_key(fid, cell), -1)
	if v <= 0:
		return 0
	return CellCodec.mat(v)

## COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): forward the current Sun direction into the near-field daylight material
## twin (the module path's shared atlas material). No-op with no module world or the flag off (the module setter
## + the atlas setter both self-guard) ⇒ byte-identical.
func set_near_daylight_sun_dir(sun_dir: Vector3) -> void:
	if _module_world != null and _module_world.has_method("set_near_daylight_sun_dir"):
		_module_world.call("set_near_daylight_sun_dir", sun_dir)
	# The per-id near-field materials (fallback mesher + module residual surfaces — slopes, translucent, water,
	# lava — + VoxelBody debris) share the one static BlockMaterials cache; feed the Sun into every daylight twin.
	# Self-guards on FP_NEAR_DAYLIGHT ⇒ flag-off is byte-identical (nothing registered, no-op).
	BlockMaterials.set_near_daylight_sun_dir(sun_dir)
	# COSMOS TEXTURED-LOD V1 (FP_SHADE_UNIFIED, §2V.6 F1): THE single uniform-push site — push the TRUE planet centre
	# (in the current render frame) to the near daylight twin at the SAME frame the sun_dir syncs, so its radial normal
	# matches the far shell's and can NEVER go stale across a facet crossing / re-anchor. render_centre() folds the
	# active facet transform (or the fixed-frame −anchor), so re-reading it every frame is inherently fresh. Off ⇒ never
	# computed / pushed ⇒ byte-identical. The GDScript-fallback path (no facet ring) leaves planet_centre at the origin,
	# which degrades the unified normal to the shipped normalize(v_wp) — safe, self-consistent.
	# COSMOS NIGHT-TERRAIN-CENTRE (fix/voxiverse-night-terrain-lit): the same TRUE planet centre push, but for the
	# ISOLATED normal-only fix (shipped shade law, unified off). Feeds BOTH the module atlas twin AND the BlockMaterials
	# fallback/residual/debris twins (which the unified path above never covered), so the near ground's day/night
	# terminator uses the true radial — killing the bright-at-night facet, the reversed east↔west sweep (the wrong
	# outward-normal inverts the mu gradient), and the re-bake lag (the centre is now refreshed EVERY frame, never
	# frozen at 0). Off ⇒ never computed / pushed ⇒ byte-identical. render_centre() folds the active facet transform
	# (or the fixed-frame −anchor) so re-reading it every frame is inherently fresh, exactly like the far shell's MODEL·0.
	if CubeSphere.near_centre_fix_on() and not CubeSphere.FP_SHADE_UNIFIED and _facet_ring != null:
		var ncentre: Vector3 = _facet_ring.render_centre()
		if _module_world != null and _module_world.has_method("set_near_daylight_planet_centre"):
			_module_world.call("set_near_daylight_planet_centre", ncentre)
		BlockMaterials.set_near_daylight_planet_centre(ncentre)
	if CubeSphere.FP_SHADE_UNIFIED and _facet_ring != null:
		var centre: Vector3 = _facet_ring.render_centre()
		if _module_world != null and _module_world.has_method("set_near_daylight_planet_centre"):
			_module_world.call("set_near_daylight_planet_centre", centre)

## COSMOS-ORBITAL-SHELL live-path telemetry: the far ring's driver→warm→emit→draw state for the remote bridge.
## {} when there is no faceted ring or the camera-set law is not engaged (⇒ the bridge stamps nothing, byte-identical).
func shell_telemetry() -> Dictionary:
	if _facet_ring == null or not _facet_ring.has_method("shell_telemetry"):
		return {}
	var t: Dictionary = _facet_ring.shell_telemetry()
	# FP_FAR_TERMINATOR_WELD sun-echo telemetry: fold in the near-field's live sun_dir (`sd_near`) alongside the
	# far-ring's own sd_shell/sd_v2 (added inside shell_telemetry above) so a live A/B can confirm ALL tiers track
	# the same Sun. Off ⇒ the key is never added ⇒ byte-identical for any telemetry consumer.
	if CubeSphere.FP_FAR_TERMINATOR_WELD and not t.is_empty():
		t["sd_near"] = BlockMaterials.daylight_sun_dir_telemetry()
	return t

## COSMOS LOD-TEXTURE Phase 2 telemetry: the far-texture bake ledger (coverage, close-up residency, per-frame bake ms,
## byte ledger) streamed via the remote bridge next to shell_telemetry(). {} when the baker is absent (flag off).
func tex_telemetry() -> Dictionary:
	if _facet_tex == null:
		return {}
	return _facet_tex.tex_telemetry()

## docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md (task #99): G2/G1a bake-progress + NEVER-OOM ledger telemetry for
## the live A/B ("mountains READ from orbit"). {} with the flag off / not yet set up ⇒ byte-identical for any
## telemetry consumer (no new keys ever appear).
func relief_data_telemetry() -> Dictionary:
	if _relief_data == null or not _relief_data.is_ready():
		return {}
	return {
		"g2_baked": _relief_data.baked_count(),
		"g2_total": _relief_data.facet_count(),
		"g2_bytes": _relief_data.resident_bytes(),
	}

## T2f (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-consumer main-thread attribution for the telemetry window. Returns
## the MAX single-frame cost (ms) of the snowfall fixed step + the load-controller tick since the last call, then resets
## the accumulators — RemoteBridge samples it once per telemetry window so a 0.5 s snowfall spike is attributed as its own
## number rather than folded anonymously into worst_ms. Read-only w.r.t. gameplay; the timers are passive ticks_usec reads.
func take_perf_attrib() -> Dictionary:
	var out := {
		"snow_ms": snappedf(float(_snow_us_max) / 1000.0, 0.01),
		"ctrl_ms": snappedf(float(_ctrl_us_max) / 1000.0, 0.01),
		# COSMOS MAIN-THREAD ORCHESTRATION TH0: the job lane's bounded MAIN-THREAD commit/drain time this window
		# (0.0 with the flag off / no lane). This is the number that must DROP as TH1+ move compute off main —
		# it isolates the main-thread commit cost from the worker compute (which no longer sits on the frame).
		"main_commit_ms": snappedf(_job_lane.take_main_commit_ms() if _job_lane != null else 0.0, 0.01),
	}
	_snow_us_max = 0
	_ctrl_us_max = 0
	return out

## path keeps the analytic far field as cover during the drop (full dual-window handoff is M4).
func maybe_flip_home_face(player_pos: Vector3) -> bool:
	if _chart == null:
		return false
	# COSMOS M5c (docs/COSMOS-M5C-CORNER.md §4): inside CORNER_ZONE_R of a vertex, drop the flip hysteresis
	# from 64 to FLIP_HYST_CORNER=5 so the player re-homes almost immediately after any edge crossing near
	# the corner (the §7 wedge-unreachability lemma needs this). The corner distance is stashed for §5's
	# anomaly check. Flag OFF → h stays FLIP_HYST → byte-identical to today.
	var h := CosmosChart.FLIP_HYST
	if CubeSphere.M5C_CORNER:
		var p := _chart.raw_of_f(player_pos.x, player_pos.z)
		var c := CosmosCorner.nearest_corner(p.x, p.y, _chart.n)
		_corner_dist = CosmosCorner.corner_dist(p.x, p.y, c)
		if _corner_dist <= float(CubeSphere.CORNER_ZONE_R):
			h = CubeSphere.FLIP_HYST_CORNER
	if not _chart.flip_needed(player_pos, h):
		return false
	var res := _chart.flip(player_pos)
	if not bool(res["ok"]):
		return false                                  # corner quadrant — deferred to M5
	# COSMOS-FRAME-ORIENTATION §5.1: chart.flip accumulated the crossed edge's D4 into M_win, so the
	# window frame is CONTINUOUS across the flip — no player/heading compensation is needed (Fix A #71
	# reverted). FLAT_WORLD never reaches here (no chart), so the flat path is unaffected.
	# Follow the new home face in the analytic/main-thread-generated worldgen queries (§4.5).
	TerrainConfig.set_active_frame(_chart.face, CubeSphere.d4_of(_chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1): atomic face+M_win, before restream
	_m5_sync_frame()   # COSMOS M5a: flip changed face + M_win → refresh the true-position chart table before restream
	# COSMOS R2.2 (M5_REAL): a home-face flip is a NEW EPOCH. Re-install the bake frame for the NEW chart NOW,
	# BEFORE the near restream + far rebase below, so the fresh face bakes into the CORRECT epoch frame. Without
	# this the near C++ mesher keeps the SPAWN frame (set_cosmos_bake was pushed only at spawn), so every
	# post-flip block bakes into a stale frame → the near terrain renders BROKEN across faces — worst near a
	# corner, where M5c's eager flips fire constantly. Anchors the new epoch at the player (the flip keeps the
	# window position unchanged). No-op unless curved + M5_REAL (m5_real_install_epoch self-guards).
	m5_real_install_epoch(player_pos)
	# Re-base the WINDOW-space collider indices onto the new face's index map: the global-keyed
	# `_edits`/`_meta` are untouched (edits are preserved), but `_edit_columns`/`_placed_top` are
	# window-keyed PERF indices, so rebuild them by unfolding every edit's global cell back into the
	# new window (a home-face-only join now maps onto the neighbour face) — the collider stays exact.
	_rebuild_window_indices()
	# COSMOS frozen-epoch flip (COSMOS-AUDIT §3.2 item 4, F3): reposition the module so its voxel
	# coordinate frame maps to the NEW face's global indices (voxel = window − node.position = global
	# index; the flip re-bases i_org/j_org), then install a NEW generator epoch (new frozen gen_face)
	# and hard-restream so stale face-A meshes are dropped. The old generator is never mutated — any
	# in-flight worker task finishes on the old face and its block is discarded by the restream.
	if _module_world != null:
		# COSMOS M4 Stage 2 (§3.2): capture the wrapper's OLD-frame position BEFORE repositioning to the new
		# frame, and pass it to set_home_face so the flag-on cover can pin the old terrain at its old world
		# spot. Default-off ignores it (freed immediately); the 1-arg race-verify call still works.
		var old_mod_pos: Vector3 = _module_world.position
		_module_world.position = _chart.node_origin()   # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org
		if _module_world.has_method("set_home_face"):
			_module_world.call("set_home_face", _chart.face, old_mod_pos, _chart.m_win())
	# COSMOS M4 (§5.1): latch the flip-settling window (both render paths). update_streaming settles it once
	# the module reports ramp_done() — re-mirroring player edits into the fresh terrain (§5.4), ending the far
	# turbo, and releasing the cover. The fallback path (no module) settles immediately (re-mirror/release are
	# module-guarded no-ops there — ChunkStreamer re-reads the overlay when it remeshes).
	_flip_settling = true
	# Re-base the far layer onto the new face's global frame (Fable Stage 1). It stashes its still-
	# world-correct tiles as a cover so the horizon holds while the near field restreams behind it —
	# the intended visual bridge that keeps the seam crossing from blanking the mid-to-far distance.
	# COSMOS M4 (§2.2): then open the handoff turbo so the new frame's nearest ring-0 tiles build FIRST
	# and appear under the player in ~0.2–0.5 s (both render paths benefit from the nearest-first turbo).
	if _far != null:
		_far.rebase_to(_chart.node_origin(), _chart.m_win())   # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org + frozen epoch M_win
		_far.begin_handoff()
	# HARD RESTREAM the fallback streamer + collider (the module was restreamed by set_home_face above).
	_restream()
	# COSMOS M4 Stage 2 telemetry: report whether the frozen near cover was actually installed (flag-gated).
	var cover_on := _module_world != null and _module_world.has_method("cover_active") \
		and bool(_module_world.call("cover_active"))
	print("[WorldManager] home-face flip %d → %d (hard restream, handoff=%s, cover=%s)"
		% [int(res["from_face"]), int(res["to_face"]), "on" if _far != null else "off", "yes" if cover_on else "no"])
	return true

## Rebuild the window-keyed PERF indices (`_edit_columns`, `_placed_top`) from the global-keyed
## overlay after a home-face flip (curved) or a facet crossing (FACETED) re-bases the window (§4.5 /
## FP-M1a §6.2). Every edit's global cell is unfolded back into the current window; edits whose cell
## is not reachable in this window (far off-face / another facet) simply do not index a column here —
## they re-index when the window returns to them. Keeps the collider's fast-path gate + above-surface
## scan exact after the reframe.
func _rebuild_window_indices() -> void:
	_edit_columns = {}
	_placed_top = {}
	# COSMOS-PERF FALL (FP_FLOOR_MEMO): a crossing/flip re-bases WINDOW columns onto different global columns, so the
	# window-keyed floor memo is stale — drop it wholesale (it re-populates lazily on the next fall). No-op off-flag.
	if CubeSphere.FP_FLOOR_MEMO:
		_floor_top = {}
	# COSMOS-MOTION-PHYS §6.3 (FP_MOVE_PROBE_CACHE): a crossing/flip also changes active_facet/datum, so the generated-
	# value cache (keyed by window cell) is stale — clear it here, the same choke point the floor memo patrols. No-op
	# off-flag; a clear just forces recompute next query.
	if CubeSphere.FP_MOVE_PROBE_CACHE:
		_gen_cache.clear()
	# FP-M1a: FACETED (no chart) — the active facet lattice IS the window, so keep this facet's edits and
	# index them directly by their unpacked cell (x, z) / y high-water mark.
	if CubeSphere.FACETED and _chart == null:
		var active := TerrainConfig.active_facet()
		# COSMOS-PERF UNATTENDED R5 (FP_EDIT_FID_INDEX): iterate ONLY the active facet's edits from the per-fid index
		# (O(active-fid)) instead of the whole `_edits` dict (O(all edits) — up to ~200 k snow cells). The index is a
		# byte-exact subset filed by the same write/erase choke points, so the rebuilt indices are IDENTICAL. Off ⇒ the
		# shipped full scan + per-key fid filter (byte-identical). `_rebuild_scanned` records the work actually paid.
		var indexed: bool = CubeSphere.FP_EDIT_FID_INDEX
		var ks: Array = _edits_by_fid.get(active, {}).keys() if indexed else _edits.keys()
		_rebuild_scanned = ks.size()
		for k in ks:
			if not indexed and FacetAtlas.edit_key_fid(k) != active:
				continue
			var cell: Vector3i = FacetAtlas.edit_key_unpack(k)[1]
			var col := Vector2i(cell.x, cell.z)
			_edit_columns[col] = true
			if int(_edits[k]) > 0:
				var prev: int = _placed_top.get(col, -0x40000000)
				if cell.y > prev:
					_placed_top[col] = cell.y
		return
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var win := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if not bool(win["found"]):
			continue
		var col := Vector2i(int(win["x"]), int(win["z"]))
		_edit_columns[col] = true
		if int(_edits[k]) > 0:                            # a PLACED (non-air) cell raises the high-water mark
			var r := int(g["r"])
			var prev: int = _placed_top.get(col, -0x40000000)
			if r > prev:
				_placed_top[col] = r

## COSMOS M4 (§5.4): re-mirror player edits into the freshly-restreamed MODULE render. A home-face flip
## rebuilds the VoxelTerrain from PURE worldgen (set_home_face → restream), so player-placed/dug cells —
## still authoritative in the global-keyed `_edits` overlay (rule 1) — vanish from the RENDER until their
## region is next edited. This re-injects them once the near ramp has loaded the data blocks: unfold every
## edit's global cell back into the CURRENT window (the _rebuild_window_indices pattern), keep only those
## within the near render radius of the player horizontally (a set-voxel on an unloaded far block would
## only error-spam), and hand the window-cell → packed dict — dug-to-air cells (packed 0) INCLUDED so holes
## re-carve — to bulk_inject in ONE call. Gameplay/collision were always correct via the overlay; this
## closes a RENDER-only gap latent since M3. No-op in FLAT_WORLD / on the fallback path (no chart / module).
## Edits beyond the near radius re-mirror the way they always have — when their region is next edited/loaded.
func _remirror_module_edits(player_pos: Vector3) -> void:
	if _chart == null or _module_world == null or not _module_world.has_method("bulk_inject"):
		return
	var radius := float(TerrainConfig.near_render_radius())
	var collected := {}
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var win := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if not bool(win["found"]):
			continue                                     # off the current extended window → re-mirrors when its region reloads
		var wx := int(win["x"])
		var wz := int(win["z"])
		# The near field renders window cells at world = window coordinate (the module node.position offset
		# maps window→global for the FROZEN generator, not for the player), so compare the window cell to the
		# player's world XZ directly — exactly the |window_xz − player_xz| test §5.4 specifies.
		if absf(float(wx) - player_pos.x) > radius or absf(float(wz) - player_pos.z) > radius:
			continue                                     # beyond the near field → its block is unloaded; skip (unchanged M3 behaviour)
		var wcell := Vector3i(wx, int(g["r"]), wz)
		collected[wcell] = _overlay_window_modifier(wcell, int(_edits[k]))   # §6.4: de-canon to the window render frame (0 included)
	if not collected.is_empty():
		_module_world.call("bulk_inject", collected)

## Drop and rebuild the near render + collider after a home-face flip (§4.5 hard restream). Guarded
## so it is a safe no-op in the headless verify (no streamer / module / collider nodes exist there).
func _restream() -> void:
	if _streamer != null and _streamer.has_method("restream"):
		_streamer.restream()
	# NOTE: the module path is restreamed by set_home_face() in maybe_flip_home_face (the epoch swap),
	# not here, so a flip installs the new generator epoch and drops old-face meshes in one step (F3).
	if _ground != null:
		_ground.rebuild_now()

## Re-key the WINDOW-space bookkeeping (which the global-keyed `_edits`/`_meta` are NOT part of) by
## −Δ so it stays consistent after an origin shift: a window column (x, z) becomes (x − Δi, z − Δj).
## These are collider/PERF indices only; the small dicts hold just the genuinely-edited columns.
func _shift_window_bookkeeping(d: Vector2i) -> void:
	var new_cols := {}
	for k: Vector2i in _edit_columns.keys():
		new_cols[k - d] = true
	_edit_columns = new_cols
	var new_top := {}
	for k: Vector2i in _placed_top.keys():
		new_top[k - d] = _placed_top[k]
	_placed_top = new_top
	# COSMOS-PERF FALL (FP_FLOOR_MEMO): an origin shift re-anchors the SAME world under shifted window coords, so the
	# memo stays valid — re-key column (x, z) → (x − Δ, z − Δ) (the topmost CELL y is unchanged). No-op off-flag.
	if CubeSphere.FP_FLOOR_MEMO and not _floor_top.is_empty():
		var new_ft := {}
		for k: Vector2i in _floor_top.keys():
			new_ft[k - d] = _floor_top[k]
		_floor_top = new_ft
	# COSMOS-MOTION-PHYS §6.3 (FP_MOVE_PROBE_CACHE): an origin shift re-keys window columns (the generated value is keyed
	# by window cell, not global) — clear wholesale rather than re-key (a per-tick transient; it repopulates next query).
	# No-op off-flag.
	if CubeSphere.FP_MOVE_PROBE_CACHE:
		_gen_cache.clear()
	if not _joint_mods.is_empty():
		var new_j := {}
		for k: Vector4i in _joint_mods.keys():
			new_j[Vector4i(k.x - d.x, k.y, k.z - d.y, k.w)] = _joint_mods[k]
		_joint_mods = new_j

# --- COSMOS M2: per-(body,face) region persistence (§1.1/§1.3) -----------------
# The curved twin of region_origin_of + save_edits/load_edits: the ZoneChunk region grid keyed by
# the GLOBAL region key (face, region_i, region_j, region_r). N is 32-aligned (§1.1) so no region
# straddles a face. These require an installed chart; the FLAT_WORLD Vector3i path above is
# untouched. Additive — nothing in the live loop calls them (byte-identical whether a save happens).

## The global region key (§1.3) of a window cell — THE per-(body,face) ZoneChunk key on the sphere.
func region_key_of(cell: Vector3i) -> int:
	return _chart.to_region_key(cell)

## Curved-mode region SAVE: compact the global-keyed overlay for the one 32³ region identified by
## `region_key` into a ZoneChunk. The region's local index order mirrors the window axes
## (x, y, z) = (i, r, j), matching the FLAT save_edits layout so a chunk reads back the same way.
func save_region(region_key: int) -> ZoneChunk:
	var zc := ZoneChunk.new()
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var gi := int(g["i"]); var gj := int(g["j"]); var gr := int(g["r"])
		if CubeSphere.region_key(int(g["face"]), gi, gj, gr) != region_key:
			continue
		var idx := ZoneChunk.local_index(gi & 31, posmod(gr, 32), gj & 31)
		zc.set_cell(idx, int(_edits[k]), _meta.get(k, null))
	return zc

## Curved-mode region LOAD: apply a ZoneChunk's cells back into the overlay for the region
## `region_key`, routing each through the single write choke point (so the global key AND metadata
## restore exactly). The chunk was saved by a global region key, so it re-materializes at the same
## GLOBAL cells regardless of the chart's CURRENT origin — the persistence twin of edit-survival.
func load_region(region_key: int, chunk: ZoneChunk, resolver: Callable = Callable()) -> void:
	var rface := CubeSphere.key_face(region_key)
	var ri := CubeSphere.key_i(region_key) << 5
	var rj := CubeSphere.key_j(region_key) << 5
	var rr := CubeSphere.key_r(region_key) * ZoneChunk.SIZE
	for idx: int in chunk.present_indices():
		var name := chunk.material_name_at(idx)
		var id := -1
		if resolver.is_valid():
			id = int(resolver.call(StringName(name)))
		else:
			id = BlockCatalog.id_of(StringName(name))
		if id < 0:
			id = BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
			push_error("WorldManager.load_region: unknown material name '%s' — substituting placeholder '%s'"
				% [name, ZoneChunk.PLACEHOLDER_MATERIAL])
		var packed := CellCodec.pack(id, chunk.modifier_at(idx), chunk.state_at(idx))
		var local := ZoneChunk.from_local_index(idx)
		# global cell → window cell (global − origin); _write_cell re-derives the same global key.
		var gi := ri + local.x
		var gr := rr + local.y
		var gj := rj + local.z
		if rface != _chart.face:
			continue                                # a region off the home face (M3 territory) is skipped
		# global (raw home-face) cell → window cell via M_win⁻¹ (COSMOS-FRAME-ORIENTATION §5.3); _write_cell
		# re-derives the same global key. Guarded above to the home face, so (gi,gj) are raw home-face indices.
		var wxy := _chart.window_of(gi, gj)
		var win := Vector3i(wxy.x, gr, wxy.y)
		_write_cell(win, packed, chunk.meta_at(idx))
		# Defensive (FP_FLOOR_BOUNDED landmine): unlike place_block, this restore path never raised the
		# per-column PLACED high-water mark, so a restored tower would be INVISIBLE to `ceil_est`/`_attitude_
		# ground_contact` (a wrong-floor / suppressed-recovery bug the moment either flag consults `_placed_top`).
		# Mirror place_block for every restored non-air cell. Cheap; no effect on the value-only round-trip gate.
		if id > BlockCatalog.AIR:
			var pkey := Vector2i(win.x, win.z)
			if win.y > int(_placed_top.get(pkey, -0x40000000)):
				_placed_top[pkey] = win.y

# --- tier-3 persistence: ZoneChunk save/load (VOXEL-DATA-STRUCTURE §4/§5) -------
# The generated world is a pure function (tier 2) and is NEVER serialized; only the edit
# overlay — the world's deviations from that function — needs persisting. `save_edits`
# compacts the overlay (+ metadata) for one 32³ region into a ZoneChunk; `load_edits`
# applies one back through the single write choke point, so the overlay and metadata are
# restored identically. This is additive: nothing in the live break/place/collapse loop
# calls it, so gameplay is byte-identical whether or not a save ever happens.

## The 32-aligned min-corner cell of the ZoneChunk region that contains `cell`.
static func region_origin_of(cell: Vector3i) -> Vector3i:
	var s := ZoneChunk.SIZE
	return Vector3i(_floor_div(cell.x, s) * s, _floor_div(cell.y, s) * s, _floor_div(cell.z, s) * s)

static func _floor_div(a: int, b: int) -> int:
	# Floored (not truncated) integer division, so negative coordinates snap DOWN to their
	# region origin (−1 → −32 for SIZE 32, not 0), keeping regions a clean tiling of the grid.
	var q := a / b
	if (a % b) != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q

## Serialize the edit overlay (+ per-cell metadata) within the 32³ region whose min corner
## is `region_origin` (must be 32-aligned — use `region_origin_of`) into a ZoneChunk. Only
## edited cells occupy the chunk; unedited cells are absent and fall back to the generated
## function on load (tier composition, §4). A region with no edits yields a uniform (unset)
## chunk that serializes to a handful of bytes (§5.5).
func save_edits(region_origin: Vector3i) -> ZoneChunk:
	var zc := ZoneChunk.new()
	var s := ZoneChunk.SIZE
	# FP-M1a: iterate the overlay projected to Vector3i cells (FLAT: the live dicts by reference; FACETED:
	# the ACTIVE facet's edits unpacked to their lattice cell — the region grid is in active-facet lattice).
	var edits_v := _overlay_v3i()
	var meta_v := _meta_v3i()
	# Union of edited cells and metadata-bearing cells in the region (a metadata cell is
	# always an edited block-entity cell today, but unioning is leak-proof regardless).
	var cells := {}
	for cell: Vector3i in edits_v.keys():
		if _in_region(cell, region_origin, s):
			cells[cell] = true
	for cell: Vector3i in meta_v.keys():
		if _in_region(cell, region_origin, s):
			cells[cell] = true
	for cell: Vector3i in cells.keys():
		var local := cell - region_origin
		var idx := ZoneChunk.local_index(local.x, local.y, local.z)
		zc.set_cell(idx, cell_value_at(cell), meta_v.get(cell, null))
	if CubeSphere.FACETED and _chart == null:
		zc.set_key_format(ZoneChunk.FIDCELL_V1)   # §6.3 fence: this region is keyed in active-facet lattice
	return zc

## Apply a ZoneChunk's present cells back into the overlay at `region_origin`, routing every
## cell through the single write choke point (`_write_cell`) so the material/modifier/state
## axes AND the metadata document are restored exactly as saved. Materials resolve by NAME
## through `resolver` (a `Callable(name: StringName) -> int`; default `BlockCatalog.id_of`),
## so a chunk stays valid even if the runtime catalog assigns different dense ids than the
## saving session did (VDS §10.1). An unknown name resolves to a logged placeholder material
## (never a crash, never data loss of the shape/state bits — §16).
func load_edits(region_origin: Vector3i, chunk: ZoneChunk, resolver: Callable = Callable()) -> void:
	if not _key_format_compatible(chunk.key_format()):
		return
	for idx: int in chunk.present_indices():
		var name := chunk.material_name_at(idx)
		var id := -1
		if resolver.is_valid():
			id = int(resolver.call(StringName(name)))
		else:
			id = BlockCatalog.id_of(StringName(name))
		if id < 0:
			id = BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
			push_error("WorldManager.load_edits: unknown material name '%s' — substituting placeholder '%s'"
				% [name, ZoneChunk.PLACEHOLDER_MATERIAL])
		var packed := CellCodec.pack(id, chunk.modifier_at(idx), chunk.state_at(idx))
		var local := ZoneChunk.from_local_index(idx)
		var wcell := region_origin + local
		_write_cell(wcell, packed, chunk.meta_at(idx))
		# Defensive (FP_FLOOR_BOUNDED landmine): mirror place_block's PLACED high-water update so a restored
		# tower is visible to `ceil_est`/`_attitude_ground_contact`. See load_region for the full rationale.
		if id > BlockCatalog.AIR:
			var pkey := Vector2i(wcell.x, wcell.z)
			if wcell.y > int(_placed_top.get(pkey, -0x40000000)):
				_placed_top[pkey] = wcell.y

static func _in_region(cell: Vector3i, origin: Vector3i, s: int) -> bool:
	return cell.x >= origin.x and cell.x < origin.x + s \
		and cell.y >= origin.y and cell.y < origin.y + s \
		and cell.z >= origin.z and cell.z < origin.z + s

## FP-M1a (§6.3): the save-format fence. A FACETED session loads only FIDCELL_V1 chunks/bundles; a
## FLAT/curved session loads only legacy (unfenced) ones. A mismatch means the region indices are in a
## different lattice frame than the loader expects (per-facet vs window/global), so refusing is the only
## safe choice — it is a fence against a cross-mode misload, not a migration (none exist in the wild).
func _key_format_compatible(fmt: String) -> bool:
	var want := ZoneChunk.FIDCELL_V1 if (CubeSphere.FACETED and _chart == null) else ""
	if fmt == want:
		return true
	push_error("WorldManager: refusing a '%s' key-format payload in a '%s' session (FP-M1a §6.3 fence)"
		% ["fidcell-v1" if fmt == ZoneChunk.FIDCELL_V1 else "legacy",
			"fidcell-v1" if want == ZoneChunk.FIDCELL_V1 else "legacy"])
	return false

# --- zone bundles: streamed material payloads (RMS §2.6/§3.4/§5) ----------------
# The final piece of runtime material streaming: a ZoneBundle packages one or more regions'
# edit overlay TOGETHER WITH the material documents the receiver needs (manifest), keyed by
# cross-session GMID, so acquiring a remote zone brings materials the local client has never
# seen. Dense LRIDs never travel — they are container-local, translated by GMID at the boundary
# (RMS §2.1). This is additive; nothing in the live loop calls it (gameplay is byte-identical).
# Transport / signing / trust are out of scope (RMS §9.3): this is the payload FORMAT only.

## Serialize the edit overlay (+ per-cell metadata) within `regions` (each a 32-aligned origin,
## use `region_origin_of`) into a self-contained ZoneBundle. Each present cell is recorded by its
## cross-session "<gmid>#<state>" key (`ZoneChunk.set_cell_keyed`), and every referenced material's
## document is gathered into the bundle manifest (from the content store when held, else
## reconstructed byte-identically from the catalog def, RMS §2.2). Regions with no edits are
## skipped. Container-local ids are compact (per-chunk palettes) and independent of this session's
## dense LRID assignment — the whole point (RMS §2.6).
func save_bundle(regions: Array) -> ZoneBundle:
	var bundle := ZoneBundle.new()
	var s := ZoneChunk.SIZE
	# FP-M1a: same Vector3i projection as save_edits (FLAT: live dicts; FACETED: active-facet edits).
	var edits_v := _overlay_v3i()
	var meta_v := _meta_v3i()
	var faceted := CubeSphere.FACETED and _chart == null
	for region_origin: Vector3i in regions:
		var cells := {}
		for cell: Vector3i in edits_v.keys():
			if _in_region(cell, region_origin, s):
				cells[cell] = true
		for cell: Vector3i in meta_v.keys():
			if _in_region(cell, region_origin, s):
				cells[cell] = true
		if cells.is_empty():
			continue
		var zc := ZoneChunk.new()
		for cell: Vector3i in cells.keys():
			var v := cell_value_at(cell)
			var mat := CellCodec.mat(v)
			bundle.reference_material(mat)           # gather its manifest document (skips air)
			var local := cell - region_origin
			zc.set_cell_keyed(ZoneChunk.local_index(local.x, local.y, local.z),
				String(BlockCatalog.key_of(mat)), CellCodec.modifier(v), CellCodec.state(v),
				meta_v.get(cell, null))
		if faceted:
			zc.set_key_format(ZoneChunk.FIDCELL_V1)   # §6.3 fence on every chunk of the bundle
		bundle.add_chunk(region_origin, zc)
	return bundle

## Apply a ZoneBundle into this world (RMS §2.6/§3.4). First registers the manifest (dedup by
## GMID — an already-known material reuses its session LRID, an unknown one gets a fresh LRID,
## a key with no/rejected document degrades to an UNRESOLVED placeholder so data stays lossless,
## RMS §8). Then translates every chunk cell's container key → THIS session's LRID and applies
## it: the overlay (`_edits` + metadata) is updated through the single write choke point (rule-1
## truth, both paths). Render mirroring: on the module path one BULK `try_set_block_data` pass
## (F10); on the fallback path per-cell through `_write_cell`. Loose bodies / collapse are NOT
## re-run (a loaded zone is authored data, not a live edit); the ground collider is rebuilt once.
func load_bundle(bundle: ZoneBundle) -> void:
	bundle.register_manifest()
	var key_to_lrid := {}
	for key: String in bundle.id_map():
		key_to_lrid[key] = bundle.resolve_key(key)

	var placeholder_id := BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
	var collected := {}                              # Vector3i -> int packed cell value
	var metas := {}                                  # Vector3i -> Dictionary
	for entry: Dictionary in bundle.chunks():
		var region_origin: Vector3i = entry["origin"]
		var chunk: ZoneChunk = entry["chunk"]
		if not _key_format_compatible(chunk.key_format()):
			continue                                 # FP-M1a §6.3 fence: skip a cross-mode chunk
		for idx: int in chunk.present_indices():
			var key := chunk.material_name_at(idx)
			var lrid := int(key_to_lrid.get(key, -1))
			if lrid < 0:
				lrid = placeholder_id
				push_error("WorldManager.load_bundle: unresolvable key '%s' — substituting placeholder '%s'"
					% [key, ZoneChunk.PLACEHOLDER_MATERIAL])
			var world_cell := region_origin + ZoneChunk.from_local_index(idx)
			collected[world_cell] = CellCodec.pack(lrid, chunk.modifier_at(idx), chunk.state_at(idx))
			var m: Variant = chunk.meta_at(idx)
			if m != null:
				metas[world_cell] = m

	# Overlay is written for every cell (both paths). On the module path defer per-cell paint and
	# mirror the render in ONE bulk pass; on the fallback path _write_cell remeshes per cell.
	var use_bulk: bool = using_module and _module_world != null and _module_world.has_method("bulk_inject")
	for world_cell: Vector3i in collected.keys():
		_write_cell(world_cell, collected[world_cell], metas.get(world_cell, null), not use_bulk)
	if use_bulk:
		_module_world.call("bulk_inject", collected)
	if _ground != null:
		_ground.rebuild_now()

# --- terrain collapse (unsupported/overloaded blocks fall) ---------------------
# The support analysis itself lives in StructuralSolver (STRUCTURAL-INTEGRITY §5);
# WorldManager owns only the resulting carve + VoxelBody spawn (_structural_update).

## The 6 axis neighbours, reused by the component grouping (and formerly the flood).
const _NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Structural-integrity update around a just-edited cell (STRUCTURAL-INTEGRITY §6):
## the StructuralSolver decides which cells detach or crumble (pass 0 connectivity —
## today's flood, so tree-chop is preserved — plus load-bearing flow + moment audit
## for player builds), and this function carves that set out and drops the 6-connected
## components as loose VoxelBody debris, exactly as the old collapse did. Cheap on the
## common case: flat digging that undercuts nothing early-outs inside solve() (pass 0
## reaches everything, pass 1 finds no overload → the solver returns an empty set).
##
## MUST be called only from the player-initiated break_terrain / place_block, never
## from a spawn path, so it cannot recurse (a landing VoxelBody is physics-side).
func _structural_update(center: Vector3i, from_pos: Vector3) -> void:
	var falling: Dictionary = StructuralSolver.solve(self, center)
	if falling.is_empty():
		return   # common case: nothing detaches, spawn nothing

	# Group the detaching cells into 6-neighbour connected components; each becomes
	# one body. Capture each cell's PACKED value BEFORE carving (so mixed grass/dirt/
	# stone and wood+leaf canopies keep their materials and, later, shape/state), then
	# carve the component and drop it as one loose body. from_pos kicks it away from
	# the breaker (Vector3.INF on a placement collapse = no kick).
	var seen: Dictionary = {}
	for start: Vector3i in falling.keys():
		if seen.has(start):
			continue
		var comp: Array[Vector3i] = []
		var cstack: Array[Vector3i] = [start]
		seen[start] = true
		while not cstack.is_empty():
			var c: Vector3i = cstack.pop_back()
			comp.append(c)
			for d: Vector3i in _NEIGHBORS_6:
				var nc := c + d
				if falling.has(nc) and not seen.has(nc):
					seen[nc] = true
					cstack.append(nc)
		var comp_ids: Dictionary = {}   # Vector3i -> int packed cell value
		for c: Vector3i in comp:
			# Strip the liquid overlay (WATER-SHORE §6) AND the snow fill/skin (SNOW-ACCUMULATION §2.5):
			# a detaching shore/snowy ramp must not take the ocean or a worldgen snow plane with it. Both
			# the liquid axis and the snow fill are worldgen/sim-owned; mass/mesh key off mat/modifier and
			# would ignore them, but the contract is "they never leave worldgen", so a detaching filled ramp
			# falls BARE (the M1 §5.5 accepted class) — dropped at the VoxelBody capture boundary.
			var cv := CellCodec.strip_liquid(cell_value_at(c))
			cv = CellCodec.with_snow_fill(cv, 0)
			comp_ids[c] = CellCodec.with_state(cv, CellCodec.state(cv) & ~CellCodec.STATE_SNOW_CAPPED)
		for c: Vector3i in comp:
			_write_cell(c, 0)
		# COSMOS-TREE-BUGS Bug 2b (FP_CHOP_COLLIDER_CARVE): disable the LIVE GroundCollider's shapes at the
		# just-carved cells BEFORE spawn_loose, so the new body doesn't spawn fully overlapping stale collider
		# geometry (rebuild_now() below only marks the rebuild dirty — it lands debounced, long after this
		# frame). Off ⇒ no-op inside carve_cells; _ground can be null pre-setup, same guard as elsewhere.
		if CubeSphere.FP_CHOP_COLLIDER_CARVE and _ground != null:
			_ground.carve_cells(comp)
		# FP-FIXED-FRAME (§5): parent collapse debris under the ActiveFrame host (else self, @ identity) so it rides
		# the play frame; the world_ref stays this WorldManager. Phase 2: spawn_loose sets the body's LOCAL transform
		# to identity (cells stay lattice), so its GLOBAL comes out T_active·cell — the block's true absolute pose,
		# where it physically sat. Frame off ⇒ global identity == local identity (parent @ identity) → byte-identical.
		VoxelBody.spawn_loose(_frame_host(), comp_ids, self, from_pos)

# --- per-joint reinforcement (STRUCTURAL-INTEGRITY §4.2/§7) ---------------------

## The canonical unordered joint key for the pair of 6-adjacent cells (a, b): the
## component-wise-smaller cell + the axis they differ on (0=x, 1=y, 2=z).
static func _joint_key(a: Vector3i, b: Vector3i) -> Vector4i:
	var axis := 0 if a.x != b.x else (1 if a.y != b.y else 2)
	return Vector4i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z), axis)

## Reinforcement id on the joint between 6-adjacent cells (a, b); 0 = unreinforced.
## The structural solver reads this for every joint's F_t/F_s/M₀ (StructuralModel).
func joint_mod(a: Vector3i, b: Vector3i) -> int:
	return int(_joint_mods.get(_joint_key(a, b), 0))

## Reinforce the joint between the two 6-adjacent cells with `reinf_id` (a
## StructuralModel reinforcement id; 0 clears it). Returns false if the cells are
## not 6-adjacent. One reinforcement per joint (placing a new one replaces the old).
func reinforce_joint(a: Vector3i, b: Vector3i, reinf_id: int) -> bool:
	var diff := b - a
	if absi(diff.x) + absi(diff.y) + absi(diff.z) != 1:
		return false
	if reinf_id == 0:
		_joint_mods.erase(_joint_key(a, b))
	else:
		_joint_mods[_joint_key(a, b)] = reinf_id
	return true

# --- analytic world queries (path-agnostic) ------------------------------------

## Walkable surface height (world y of the top of the ground) at (x, z), accounting
## for broken blocks from the TOP — used for spawning pillars and the grounded test.
## COSMOS FS2′ (docs/COSMOS-FACET-SEAMS-V2.md §2): the placed/walked surface sits at PLAY y = cell y + s
## (the per-column datum lift). floor_under/blocked/ceiling_scan/the DDA and the near mesh all report/emit in
## PLAY space (+ s) — this is the SAME surface the render draws (verify_facet_seams G-D2-SHAPE defines the
## rendered near-mesh top as effective_height+1 + s). surface_y drives spawn, set_alt/teleport, the grounded
## clamp, VoxelBody rest and the border pillars, so it MUST add s too: omitting it placed the player s blocks
## (up to the facet-centre sagitta, ~5-7 @ R=6371) BELOW the visible ground — a set_alt(5)/spawn that sinks.
## s ≡ 0.0 with FP_DATUM_BAKE off (and in flat/curved mode, where _active_facet < 0) ⇒ byte-identical; this
## rides FP_DATUM_BAKE's own gate. Mirrors floor_under's no-floor fallback (float(effective_height+1) + s).
## COSMOS FALL-THROUGH ROOT (FP_QUERY_FRAME_GUARD §2.1): `pos_fid`, the caller's pose stamp; a trailing y is not
## part of this query's contract (surface_y is a pure COLUMN lookup), so the reframe uses y = 0.0 — the facet's
## own tangent-plane datum — as the canonical height for identifying the SAME physical column in the active
## facet's frame (a judgment call: floor_under/blocked/ceiling_scan reframe the caller's REAL y because they also
## need a correct feet/head height back; surface_y only ever needs the resulting x/z). Default (-1) or a matching
## facet ⇒ byte-identical.
func surface_y(x: float, z: float, pos_fid: int = -1) -> float:
	if CubeSphere.FP_QUERY_FRAME_GUARD and pos_fid >= 0:
		var g := _guard_reframe(x, 0.0, z, pos_fid)
		x = g.x; z = g.z
	var xi := int(floor(x))
	var zi := int(floor(z))
	return float(effective_height(xi, zi) + 1) + _datum_lift(xi, zi)

## COSMOS-AGENT-AUTONOMY — PLAY→CELL Y for a column. The player's pose (`player.position`) lives in PLAY space,
## where `play y = cell y + s` and `s` is this column's continuous datum lift; `block_id_at`/`cell_solid` (and the
## whole agent nav/query layer built on them) live in CELL space. X/Z carry NO lift on the facet plane, so only Y
## is remapped. Called ONLY from the CONTROL_ENABLED + FP_AGENT_* gated executor (RemoteControl) ⇒ no normal-play
## path reaches it and `s ≡ 0.0` with FP_DATUM_BAKE off ⇒ this is the identity (byte-identical) in the FLAT gate.
func play_y_to_cell_y(x: float, z: float, play_y: float) -> float:
	return play_y - _datum_lift(int(floor(x)), int(floor(z)))

## The y the player should stand at in column (x, z) given their current feet
## height. Plain, NO-CLIMB floor: scan DOWN from the feet for the first solid block
## that has AIR directly above it (the actual standable surface) and stand on its
## top. Crucially it does NOT pop the player up to the column top when the feet cell
## is buried — walling into a hillside must not teleport the player onto the hilltop.
## Horizontal movement into terrain is now stopped by blocked() (the player queries
## it per-axis), so the feet are always at or just above an air-topped surface and a
## valid floor is always found; the scan honours dug shafts/tunnels below as well.
## COSMOS FS2′ (docs/COSMOS-FACET-SEAMS-V2.md §2.2.4) — this column's CONTINUOUS datum lift s: the play↔cell boundary
## map (play y = cell y + s). The physics funnels below (floor_under/blocked/ceiling/DDA) evaluate voxel CONTENT in
## cell space and report in PLAY space by adding s per column (the content is byte-identical — FS2′ shifts the
## boundary, not the world). 0.0 unless FP_DATUM_BAKE and an active facet ⇒ every funnel is byte-identical off.
func _datum_lift(xi: int, zi: int) -> float:
	if not (CubeSphere.FP_DATUM_BAKE and CubeSphere.FACETED):
		return 0.0
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return 0.0
	return FacetAtlas.datum_lift(fid, float(xi) + 0.5, float(zi) + 0.5)

## FP_QUERY_FRAME_GUARD helper (docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §2.1) — re-express (x,y,z),
## stamped in facet `pos_fid`, into `TerrainConfig.active_facet()`'s lattice via the f64-exact
## `FacetAtlas.reframe_position64`, the SAME math `_heal_frame_desync` uses to keep the player's own pose
## continuous across a crossing. Called only from behind `CubeSphere.FP_QUERY_FRAME_GUARD and pos_fid >= 0` in
## each of the four physics funnels below, so the flag-off / default (`pos_fid == -1`) path never reaches this
## function at all (one compare, no call). `pos_fid == active facet` is also a no-op (still no reframe).
func _guard_reframe(x: float, y: float, z: float, pos_fid: int) -> Vector3:
	var active := TerrainConfig.active_facet()
	if pos_fid == active:
		return Vector3(x, y, z)
	var w: Array = FacetAtlas.reframe_position64(pos_fid, active, x, y, z)
	return Vector3(w[0], w[1], w[2])

func floor_under(x: float, z: float, feet_y: float, pos_fid: int = -1) -> float:
	# COSMOS FALL-THROUGH ROOT (FP_QUERY_FRAME_GUARD, docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §2.1): the
	# caller's pose stamp `pos_fid` may have drifted from the active facet (a crossing committed set_active_facet
	# but the caller hasn't re-expressed its pose yet this frame). Re-express the query point ONCE so the scan
	# below reads the SAME physical column the caller means, never a decorrelated neighbour's. Default (-1) or a
	# matching facet ⇒ byte-identical (one compare).
	if CubeSphere.FP_QUERY_FRAME_GUARD and pos_fid >= 0:
		var g := _guard_reframe(x, feet_y, z, pos_fid)
		x = g.x; feet_y = g.y; z = g.z
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)   # in-cell footprint (ignored by full cubes; used by P5 shapes)
	var fz := z - float(zi)
	# COSMOS FS2′: convert the PLAY feet to CELL space for the (content) scan, report the found top back in PLAY
	# space (+ s). s ≡ 0.0 with FP_DATUM_BAKE off ⇒ byte-identical.
	var s := _datum_lift(xi, zi)
	# COSMOS FALL-THROUGH GUARD (FP_FLOOR_SURFACE_WELD, docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §2.2): the
	# column's analytic surface in PLAY space — the SAME expression `surface_y` returns for (xi, zi). Computed once
	# (O(1), `effective_height` is the memoized column read the scan below already warms) so both weld sites can
	# reuse it. Off ⇒ left at 0.0 and never read (the weld clauses below are themselves flag-gated).
	var surface_play_y := 0.0
	if CubeSphere.FP_FLOOR_SURFACE_WELD:
		surface_play_y = float(effective_height(xi, zi) + 1) + s
	var cell_feet := feet_y - s
	# Start at the feet directly (NO clamp to the noise top): players stand on trees
	# and placed towers ABOVE the heightmap, and clamping down would teleport them
	# off. (The scan length used to be justified as "bounded by the fall distance —
	# cheap"; that is FALSE for a fall from orbit — feet ≈ R+900 ⇒ ~900 cell_value_at
	# queries/call ⇒ ~86 ms/frame. FP_FLOOR_BOUNDED below bounds it.)
	var start := int(floor(cell_feet + 0.5))
	var y := start
	_floor_scan_iters = 0
	var populate := false          # true ⇒ the tail scan starts ABOVE all solids, so its first floor IS the column's topmost (cacheable)
	# COSMOS-PERF FALL (FP_FLOOR_BOUNDED): PROBE the first MARGIN cells DOWN from the feet. Near the surface
	# (walking/standing/landing — feet within MARGIN of the floor) the floor is found in the first 1-2 cells, so
	# this loop returns the SAME value scanning the SAME cells in the SAME order as the shipped unbounded scan —
	# BIT-IDENTICAL. Only if the probe finds NO floor (the feet are more than MARGIN above everything near them —
	# a fall) do we skip the guaranteed-generated-air gap by jumping the scan to a cheap heightmap-based start.
	# Off ⇒ this whole block is skipped (y stays = start) and the loop below is the shipped scan verbatim.
	if CubeSphere.FP_FLOOR_BOUNDED:
		# COSMOS-PERF FALL (FP_FLOOR_MEMO): if this column's topmost solid-with-air-above is cached AND the feet are
		# at/above it, nothing solid sits above that cell (proof: a higher solid would itself be a higher
		# solid-with-air-above), so a scan from the feet reaches it through air alone — jump STRAIGHT there and let
		# the tail loop return it in one iteration (O(1); skips the probe). Off ⇒ the sentinel ⇒ this never fires.
		var cached := int(_floor_top.get(Vector2i(xi, zi), _FLOOR_MEMO_NONE)) if CubeSphere.FP_FLOOR_MEMO else _FLOOR_MEMO_NONE
		if cached != _FLOOR_MEMO_NONE and start >= cached:
			y = cached
		else:
			var probe_floor := start - CubeSphere.FLOOR_BOUNDED_MARGIN
			while y > probe_floor:
				_floor_scan_iters += 1
				var hp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
				if hp != Vector2.ZERO and _occ_span(cell_value_at(Vector3i(xi, y + 1, zi)), fx, fz) == Vector2.ZERO:
					var probe_play_y := float(y) + hp.y + s
					# COSMOS FALL-THROUGH GUARD (FP_FLOOR_SURFACE_WELD §2.2): an un-edited column's true floor never
					# sits MORE THAN FLOOR_WELD_EPS below the analytic surface (no-caves law; the epsilon covers the
					# legitimate in-cell deficit of shaped/slope/snow cells and the water-seafloor smoothing span —
					# FablePhys hardening #1, verify_floor_weld's no-fire arm pins it) — a found floor meaningfully
					# below it is a stale-frame lie (§1.2), so weld up to the surface. `_edit_columns` exempts dug
					# shafts/tunnels (a real below-surface stand), preserving shipped behaviour there exactly. Off
					# ⇒ dead code.
					if CubeSphere.FP_FLOOR_SURFACE_WELD and probe_play_y < surface_play_y - CubeSphere.FLOOR_WELD_EPS and not _edit_columns.has(Vector2i(xi, zi)):
						return _ssw_weld(xi, zi, x, z, surface_play_y)
					return _ssw_weld(xi, zi, x, z, probe_play_y)
				y -= 1
			# Nothing solid within MARGIN of the feet. Compute a cheap CEILING on the highest solid cell in the
			# column — the greater of (a) `col_height + MARGIN`: `col_height` is the procedural heightmap TOP, a
			# DIRECT query (no scan), and every generated solid (terrain + trees, ≤ MAX_ABOVE_SURFACE=14 higher) sits
			# at or below it; and (b) `placed_top + 1`: the per-column high-water of PLAYER-PLACED cells (an O(1)
			# `_placed_top` lookup), so a tower rising ABOVE the heightmap+MARGIN is still covered exactly. Jump the
			# scan to that ceiling — skipping the pure-air gap above it the shipped path would grind through — but
			# NEVER move the scan UP past where the probe already reached (`mini` keeps it a continuation when the
			# ceiling is not below). The jump lands the scan just above the true floor, so it finds the SAME floor
			# the shipped from-feet scan would (bit-identical), now in ≤ ~MARGIN cells instead of ∝ feet altitude.
			var ceil_est := maxi(col_height(xi, zi) + CubeSphere.FLOOR_BOUNDED_MARGIN, placed_top(xi, zi) + 1)
			y = mini(y, ceil_est)
			# We reach the ceiling (y == ceil_est) only when it is BELOW the probed band ⇒ the scan now starts above
			# EVERY solid in the column, so the first floor it finds is the column's topmost surface — safe to memoize.
			populate = CubeSphere.FP_FLOOR_MEMO and y == ceil_est
	# Merged contract (INTEGRATION-DECISIONS §3): the per-cell test is `_occ_span`, so
	# non-solid materials (water) yield the empty span and are scanned THROUGH to the
	# seafloor, while a solid cell yields its filled interval — the floor is the top of
	# the first occupied cell that has an empty span directly above (its top = span.y;
	# 1.0 for a full cube ⇒ float(y+1), byte-identical to the old solid/air-above test).
	# COSMOS-PERF FALL (FP_FLOOR_MEMO) footprint-safety: `populate` is only true when the scan jumped to
	# `ceil_est` — a footprint-INDEPENDENT ceiling above EVERY solid in the column — so the descent passes
	# through the whole air gap first. `memo_safe` stays true only while every above-floor cell is plain
	# (footprint-independent) air; a shaped/ramp/seam cell (solid material but empty span at THIS footprint)
	# flips it false, because at another footprint that cell could BE the floor. We then cache only when the
	# found floor is itself a plain full cube — guaranteeing a HIT reproduces this floor at ANY footprint.
	var memo_safe := true
	while y > -1024:
		_floor_scan_iters += 1
		var v_here := cell_value_at(Vector3i(xi, y, zi))
		var here := _occ_span(v_here, fx, fz)
		if here != Vector2.ZERO and _occ_span(cell_value_at(Vector3i(xi, y + 1, zi)), fx, fz) == Vector2.ZERO:
			if populate and memo_safe and _span_indep_full(v_here):
				_floor_memo_put(Vector2i(xi, zi), y)
			var tail_play_y := float(y) + here.y + s
			# COSMOS FALL-THROUGH GUARD (FP_FLOOR_SURFACE_WELD §2.2): same epsilon-gated weld as the probe-loop
			# return above — see that comment. Off ⇒ dead code.
			if CubeSphere.FP_FLOOR_SURFACE_WELD and tail_play_y < surface_play_y - CubeSphere.FLOOR_WELD_EPS and not _edit_columns.has(Vector2i(xi, zi)):
				return _ssw_weld(xi, zi, x, z, surface_play_y)
			return _ssw_weld(xi, zi, x, z, tail_play_y)
		if populate and not _span_indep_empty(v_here):
			memo_safe = false          # a footprint-DEPENDENT cell sits above the floor → unsafe to cache this column
		y -= 1
	return _ssw_weld(xi, zi, x, z, float(effective_height(xi, zi) + 1) + s)

## COSMOS SEAM-SLOPE WELD (docs/COSMOS-SEAM-SLOPE-WELD-DESIGN.md §3, FP_SEAM_SLOPE_WELD) — clamp the just-computed
## collision floor `base_play_y` (in the ACTIVE facet's play space at continuous column (x, z)) UP to the NEIGHBOUR
## facet's junction-aware band surface, but ONLY inside the seam band |own_dist| ≤ SEAM_WELD_BAND. Off / non-faceted
## / no active facet ⇒ returns `base_play_y` unchanged after ONE flag compare (every floor_under return is byte-
## identical). A dug column (`_edit_columns`) is EXEMPT — the same shaft exemption FP_FLOOR_SURFACE_WELD uses, so a
## seam shaft the player dug is never welded shut. `max(base, neighbour)` never lowers the floor and never sits below
## either side's rendered slope; symmetric across the crossing (see design §3.1). Band-gated ⇒ the facet interior is
## byte-identical (the min-slot own_dist exceeds the band there, so the branch returns early — #111 untouched).
func _ssw_weld(xi: int, zi: int, x: float, z: float, base_play_y: float) -> float:
	if not (CubeSphere.FP_SEAM_SLOPE_WELD and CubeSphere.FACETED):
		return base_play_y
	var A := TerrainConfig.active_facet()
	if A < 0 or _edit_columns.has(Vector2i(xi, zi)):
		return base_play_y
	# Nearest seam slot's |own_dist| at the query column (base surface feet). One plane dot per ≤ 4 slots — the
	# same cost class as the FACETED ridge-wall test in `blocked`. Outside the band ⇒ no weld (interior byte-exact).
	var pl := FacetAtlas.seam_planes_f64(A)
	var slot := -1
	var best := 1e30
	for s in 4:
		var a := pl[s * 4]; var b := pl[s * 4 + 1]; var c := pl[s * 4 + 2]; var d := pl[s * 4 + 3]
		var gl := sqrt(a * a + b * b + c * c)
		if gl <= 1e-12:
			continue
		var v: float = absf(a * x + b * base_play_y + c * z + d) / gl
		if v < best:
			best = v; slot = s
	if slot < 0 or best > CubeSphere.SEAM_WELD_BAND:
		return base_play_y
	var B := FacetAtlas.seam_neighbour(A, slot)
	if B < 0:
		return base_play_y
	# This column's base surface as a WORLD point in A, and its radius. The neighbour's band surface at the SAME
	# physical point is a world radius too (frame-pure, GenCtx(B) — no set_active_facet), so `max` is frame-free.
	var wA := FacetAtlas.lattice_to_world64(A, x, base_play_y, z)
	var r_base: float = sqrt(wA[0] * wA[0] + wA[1] * wA[1] + wA[2] * wA[2])
	var r_nb := _facet_band_surface_r(B, wA[0], wA[1], wA[2])
	if r_nb <= r_base:
		return base_play_y
	# Convert the (higher) neighbour radius back to a play-y in A: r is ~affine in play-y along the column, so one
	# extra world sample gives the local dr/dy (≈ 1). The clamp only ever RAISES the floor (max), never lowers it.
	var wA1 := FacetAtlas.lattice_to_world64(A, x, base_play_y + 1.0, z)
	var r_base1: float = sqrt(wA1[0] * wA1[0] + wA1[1] * wA1[1] + wA1[2] * wA1[2])
	var drdy := r_base1 - r_base
	if drdy <= 1e-6:
		return base_play_y
	return base_play_y + (r_nb - r_base) / drdy

## FP_SEAM_SLOPE_WELD — facet F's FRAME-PURE junction-aware band surface at world point (wx,wy,wz), returned as a
## WORLD RADIUS. Mirrors probe_seam_slope's `_frame_floor` MINUS the scan: a GenCtx(0, F) worker-path context feeds
## the pure static column funnels (no `set_active_facet`, no `_chart`, no memo churn), so it is safe to evaluate for
## the NEIGHBOUR facet while A is active. The band top follows the design §3.1 branch — the FAM_JUNCTION run-top
## `hi` (the clipped-cube ladder) ONLY where the top run cell STRADDLES a seam (so both facets present the same `hi`
## in the junction strip → the `max` welds continuously across the commit), the CONTINUOUS carve plane (bilerp of
## the whole corner targets) where a slope fires OUTSIDE the strip (so entering the band from the facet interior
## adds ~nothing — the carve planes agree there), else the plain surface g+S+1. Datum shift S and the FP_DATUM_BAKE
## continuous lift are the same terms `surface_y`/`_datum_lift` add.
func _facet_band_surface_r(F: int, wx: float, wy: float, wz: float) -> float:
	var l := FacetAtlas.world_to_lattice64(F, wx, wy, wz)
	var xi := int(floor(l[0]))
	var zi := int(floor(l[2]))
	var fx: float = l[0] - float(xi)
	var fz: float = l[2] - float(zi)
	var ctx := TerrainConfig.GenCtx.new(0, F)
	var g: int = TerrainConfig.column_top(xi, zi, ctx)
	var S: int = FacetAtlas.datum_shift(F, xi, zi)
	var lift := 0.0
	if CubeSphere.FP_DATUM_BAKE:
		lift = FacetAtlas.datum_lift(F, l[0], l[2])
	var srun: int = TerrainConfig.slope_run_of(xi, zi, ctx)
	var top_play: float
	if TerrainConfig.slope_run_fires(srun):
		var rng: Vector2i = TerrainConfig.slope_run_range(srun, g + S)   # run [lo, hi−1] in datum space; hi = ladder top
		var st := FacetAtlas.cell_seam_state(F, xi, rng.y - 1, zi)       # does the top run cell straddle a ridge?
		var straddles: PackedInt32Array = st["straddle"]
		if not bool(st["air"]) and not straddles.is_empty():
			top_play = float(rng.y) + lift                              # junction strip → the clipped-cube ladder top hi
		else:
			# The carve plane: bilerp the four WHOLE corner targets Tw over the in-cell footprint (crack-free, §3.1).
			var m: int = TerrainConfig.slope_run_modifier_at(srun, g + S, rng.x)
			var d: Vector4i = CellCodec.slope_deltas(m)
			var t00 := float(rng.x + d.x); var t10 := float(rng.x + d.y)
			var t11 := float(rng.x + d.z); var t01 := float(rng.x + d.w)
			top_play = t00 * (1.0 - fx) * (1.0 - fz) + t10 * fx * (1.0 - fz) + t11 * fx * fz + t01 * (1.0 - fx) * fz + lift
	else:
		top_play = float(g + S + 1) + lift
	var w := FacetAtlas.lattice_to_world64(F, l[0], top_play, l[2])
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])

## FP_SEAM_SLOPE_WELD — the welded surface play-y for active-facet column (xi, zi) at its OWN plain surface, for the
## GroundCollider seam cap (`_emit_column`). Returns −INF when the weld does not apply (flag off / not faceted / no
## active facet / dug column / outside the band / neighbour not higher), so the collider adds NO extra geometry then.
const _SSW_NO_CAP := -1e30
func seam_weld_cap_playy(xi: int, zi: int) -> float:
	if not (CubeSphere.FP_SEAM_SLOPE_WELD and CubeSphere.FACETED):
		return _SSW_NO_CAP
	var A := TerrainConfig.active_facet()
	if A < 0 or _edit_columns.has(Vector2i(xi, zi)):
		return _SSW_NO_CAP
	# The column's OWN plain surface play-y (effective_height + 1 + datum lift) — the same base floor_under welds.
	var base := float(effective_height(xi, zi) + 1) + _datum_lift(xi, zi)
	var welded := _ssw_weld(xi, zi, float(xi) + 0.5, float(zi) + 0.5, base)
	if welded <= base + 1e-4:
		return _SSW_NO_CAP
	return welded

## FP_FLOOR_MEMO: store column `col`'s topmost-standable CELL y. NEVER-OOM — past FLOOR_MEMO_CAP columns the whole
## memo is dropped (a clear only forces a recompute, which is bit-identical), so the dict can never grow unbounded.
func _floor_memo_put(col: Vector2i, top_y: int) -> void:
	if _floor_top.size() >= CubeSphere.FLOOR_MEMO_CAP and not _floor_top.has(col):
		_floor_top.clear()
	_floor_top[col] = top_y

## FP_FLOOR_MEMO footprint-safety predicates. `floor_under`'s memo caches a column's floor by CELL index only,
## but `_occ_span` varies WITHIN a cell for shaped terrain — a ramp/slab/junction cell (SUB-VOXEL-SMOOTHING,
## default on) is solid at one in-cell footprint and air at another, and snow raises the top by a footprint-
## dependent amount. A column is safe to memoize ONLY when its topmost floor is a PLAIN FULL CUBE (span (0,1)
## for EVERY footprint) and every cell above it is PLAIN air (span ZERO for every footprint); then a cache HIT
## jumps to that cell and the tail scan reproduces the SAME floor at ANY footprint (no shaped cell above can
## become the real, higher floor at a different footprint). Any nonzero shape modifier or snow fill makes the
## span footprint-DEPENDENT, so such a column is excluded and falls back to the (always-correct) bounded scan.
func _span_indep_full(v: int) -> bool:
	return BlockCatalog.solidity_of(CellCodec.mat(v)) >= 0.5 and CellCodec.modifier(v) == 0 and CellCodec.snow_fill(v) == 0
func _span_indep_empty(v: int) -> bool:
	return BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5

## Max in-cell rise a walker may auto-step over without being blocked (SVS §5.2). A
## full cube's rise is 1.0 m > STEP_MAX, so every full cube still blocks (byte-identical
## to flat/blocky ground); a ramp/slab surface `<= STEP_MAX` above the feet is walked
## up, not blocked (the deliberate half-slab-as-stairs side effect).
const STEP_MAX := 0.55
## Player standing body height (feet → head) used for the headroom test.
const _BODY_HEIGHT := 1.8
const _EPS := 1e-6

## True if the player cannot stand at column (floor(x), floor(z)) with feet at feet_y
## because the standable surface just ahead is too tall to step onto (> STEP_MAX above
## the feet) OR the body would clip a solid cell overhead (SUB-VOXEL-SMOOTHING §5.2).
## Composes over the merged `floor_under`/`_occ_span`, so the material gate comes for
## free (water never blocks) and shapes auto-step. BYTE-IDENTICAL for the current
## all-full-cube world: a full cube ahead raises the standable surface 1.0 m (> STEP_MAX
## → wall), a body span overlapping the ground finds its surface far above the buried
## feet (→ wall), and open air raises nothing (→ not blocked).
func blocked(x: float, z: float, feet_y: float, pos_fid: int = -1) -> bool:
	# COSMOS FALL-THROUGH ROOT (FP_QUERY_FRAME_GUARD §2.1): see floor_under's preamble comment. The internal
	# floor_under call below inherits the (already reframed) x/z/feet_y and needs no `pos_fid` of its own.
	if CubeSphere.FP_QUERY_FRAME_GUARD and pos_fid >= 0:
		var g0 := _guard_reframe(x, feet_y, z, pos_fid)
		x = g0.x; feet_y = g0.y; z = g0.z
	var xi := int(floor(x))
	var zi := int(floor(z))
	# COSMOS FS2′: this column's play↔cell lift (0.0 unless FP_DATUM_BAKE). The ridge-wall own_dist test is a
	# near-vertical plane distance, so it is evaluated in CELL space (feet_y − s); the headroom cell scan below
	# takes a CELL-space top (top − s). floor_under already reports PLAY space. s ≡ 0.0 off ⇒ byte-identical.
	var s := _datum_lift(xi, zi)
	# COSMOS FACETED §5.3: the ridge wall. Until the FP3 handoff lets the player cross onto the neighbour, an
	# invisible wall sits just inside each active-facet ridge plane, so the player can stand on the own-side of
	# every junction cell but not walk past P into the masked void. One own_dist test per ≤4 seams.
	if CubeSphere.FACETED:
		var fid := TerrainConfig.active_facet()
		if fid >= 0:
			for slot in 4:
				if FacetAtlas.own_dist(fid, slot, x, feet_y - s, z) < FACET_WALL_EPS:
					return true
	var fx := x - float(xi)
	var fz := z - float(zi)
	# Standable height at the target column, allowing an auto-step up to STEP_MAX.
	var top := floor_under(x, z, feet_y + STEP_MAX)
	if top - feet_y > STEP_MAX:
		return true                                    # rise too big → wall (a full cube's 1.0 always is)
	# Headroom above the (possibly auto-stepped) floor: the body must not clip a solid
	# cell in (top, top + body height) at this footprint. _headroom_clear scans CELLS ⇒ cell-space top (top − s).
	return not _headroom_clear(xi, zi, fx, fz, top - s)

## True if the player's body column (top .. top + body height) at footprint (fx, fz)
## in column (xi, zi) is clear of solid occupancy (SVS §5.2). The cell whose top the
## player stands on ends exactly at `top`, so it never counts as a clip (its interval
## upper bound == top, tested with an epsilon bias). A TOP-anchored slab / full cube
## overhead correctly blocks standing.
func _headroom_clear(xi: int, zi: int, fx: float, fz: float, top: float) -> bool:
	var head := top + _BODY_HEIGHT
	var y := int(floor(top))
	var y_hi := int(floor(head - _EPS))
	while y <= y_hi:
		var sp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if sp != Vector2.ZERO:
			var occ_lo := float(y) + sp.x
			var occ_hi := float(y) + sp.y
			if occ_hi > top + _EPS and occ_lo < head - _EPS:
				return false
		y += 1
	return true

## Lowest solid UNDERSIDE overhead a rising head sweeps into, or INF if clear. Scans
## every cell the head passes through — from `from_head_y` up to `to_head_y` — at the
## footprint (x, z), the upward mirror of `floor_under`'s downward scan, so a fast rise
## (frame hitch) cannot tunnel a thin ceiling. Each cell is tested by the shape-aware
## `_occ_span` (material gate for free: water/lava yield the empty span and are scanned
## THROUGH), and the returned value is the occupied cell's lower bound — a top-anchored
## slab stops the head at its true underside, a full cube at the integer cell floor. A
## cell whose occupancy starts at/below where the head already is (occ_lo < from_head_y)
## is ignored: the head is already clear there, only NEW occupancy overhead constrains
## the move. BYTE-IDENTICAL to a single full-cube point test for the current world.
func ceiling_scan(x: float, z: float, from_head_y: float, to_head_y: float, pos_fid: int = -1) -> float:
	# COSMOS FALL-THROUGH ROOT (FP_QUERY_FRAME_GUARD §2.1): see floor_under's preamble comment. Two bounds ⇒ two
	# reframes (the reframe is affine but not y-independent — a facet-tilt shear can carry a small in-plane drift
	# with height — so from_head_y and to_head_y are each re-expressed exactly; both share the same x/z column,
	# which the first reframe fixes for the whole scan).
	if CubeSphere.FP_QUERY_FRAME_GUARD and pos_fid >= 0:
		var g0 := _guard_reframe(x, from_head_y, z, pos_fid)
		var g1 := _guard_reframe(x, to_head_y, z, pos_fid)
		x = g0.x; z = g0.z
		from_head_y = g0.y
		to_head_y = g1.y
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	# COSMOS FS2′: convert the PLAY head span to CELL space for the content scan, report the underside back in PLAY
	# space (+ s). s ≡ 0.0 with FP_DATUM_BAKE off ⇒ byte-identical.
	var s := _datum_lift(xi, zi)
	var from_cell := from_head_y - s
	var to_cell := to_head_y - s
	var y := int(floor(from_cell))
	var y_hi := int(floor(to_cell))
	while y <= y_hi:
		var sp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if sp != Vector2.ZERO:
			var occ_lo := float(y) + sp.x
			if occ_lo >= from_cell - _EPS:
				return occ_lo + s
		y += 1
	return INF

func is_solid(pos: Vector3) -> bool:
	return cell_solid(Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z))))

## Voxel-DDA ray (Amanatides & Woo) against the heightmap. Returns
## {hit, voxel:Vector3i, normal:Vector3i, position:Vector3}.
##
## Merged contract (INTEGRATION-DECISIONS §3): the DDA cell walk is unchanged; each
## cell is tested by the MATERIAL gate first (`cell_solid` = solidity ≥ 0.5), so the
## ray passes THROUGH non-solid materials (water/lava) and targets what's behind
## them. A hit on a solid cell reports the cell-BOUNDARY crossing (today's fast path,
## exact for modifier 0). P5 SEAM: for a shaped (ramp) cell, `cell_solid` still gates
## entry, then an in-cell surface ray test (SVS §5.3) refines the hit point/normal
## within the cell — full cubes need no refinement, so the boundary hit stands.
## COSMOS FS2′ (docs/COSMOS-FACET-SEAMS-V2.md §2.2.5): the aim ray is cast in PLAY space against the rendered
## (datum-lifted) surface. Lower the origin by the ray column's continuous s to CELL space, walk the DDA against
## CONTENT (byte-identical, shipped path), then lift the returned hit POSITION back to play space by the HIT
## column's s (the highlight renders at + s). Off (FP_DATUM_BAKE / non-faceted / no active facet) ⇒ the shipped
## path verbatim — byte-identical. The returned `voxel` is a content cell either way (break/place stays cell-space).
func aimed_voxel(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
	if not (CubeSphere.FP_DATUM_BAKE and CubeSphere.FACETED and TerrainConfig.active_facet() >= 0):
		return _aimed_voxel_cell(origin, dir, max_dist)
	var s0 := _datum_lift(int(floor(origin.x)), int(floor(origin.z)))
	var res := _aimed_voxel_cell(Vector3(origin.x, origin.y - s0, origin.z), dir, max_dist)
	if res.has("position"):
		var p: Vector3 = res["position"]
		var sh := s0
		if bool(res.get("hit", false)):
			var v: Vector3i = res.get("voxel", Vector3i.ZERO)
			sh = _datum_lift(v.x, v.z)
		res["position"] = Vector3(p.x, p.y + sh, p.z)
	return res

func _aimed_voxel_cell(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
	var d := dir.normalized()
	var cell := Vector3i(int(floor(origin.x)), int(floor(origin.y)), int(floor(origin.z)))
	var step := Vector3i(signi(int(sign(d.x))), signi(int(sign(d.y))), signi(int(sign(d.z))))
	var t_max := Vector3(_first_cross(origin.x, d.x), _first_cross(origin.y, d.y), _first_cross(origin.z, d.z))
	var t_delta := Vector3(
		INF if d.x == 0.0 else 1.0 / absf(d.x),
		INF if d.y == 0.0 else 1.0 / absf(d.y),
		INF if d.z == 0.0 else 1.0 / absf(d.z))
	var t := 0.0
	var normal := Vector3i.ZERO

	# The starting cell could already be solid (e.g. camera clipping ground).
	if _cell_solid(cell):
		return {"hit": true, "voxel": cell, "normal": Vector3i.UP,
			"position": origin}

	while t <= max_dist:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x; t = t_max.x; t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			cell.y += step.y; t = t_max.y; t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			cell.z += step.z; t = t_max.z; t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
		if _cell_solid(cell):
			var v := cell_value_at(cell)
			var m := CellCodec.modifier(v)
			if m == 0:
				return {"hit": true, "voxel": cell, "normal": normal,
					"position": origin + d * t}   # full cube: boundary hit (unchanged fast path)
			# Shaped cell (SVS §5.3): in-cell surface test. t is the entry into this
			# cell; the exit is the next boundary crossing on any axis.
			var t_out: float = minf(t_max.x, minf(t_max.y, t_max.z))
			var res := _ray_vs_partial(m, cell, origin, d, t, t_out, normal)
			if not res.is_empty():
				return res
			# Miss: the ray passed through the empty part of the cell — continue the DDA.
	return {"hit": false, "voxel": Vector3i.ZERO, "normal": Vector3i.ZERO,
		"position": origin + d * max_dist}

## In-cell ray test against a shaped (non-full) solid cell (SUB-VOXEL-SMOOTHING §5.3).
## The caller has already applied the material gate. Completeness: every boundary face
## of a corner-height shape is either on the cell boundary (covered by the entry-point
## occupancy test) or on the 1–2 surface triangles (covered by ray/plane tests). The
## reported `normal` stays axis-aligned (the DDA face for a boundary hit, UP/DOWN for a
## surface hit) to preserve the break/place adjacency contract; the true sloped normal
## is exposed as `surface_normal`. Empty dict = miss (the DDA continues).
func _ray_vs_partial(m: int, cell: Vector3i, origin: Vector3, d: Vector3,
		t_in: float, t_out: float, dda_normal: Vector3i) -> Dictionary:
	var base := Vector3(cell)
	var p_in := origin + d * t_in - base
	if ShapeCodec.occupied(m, p_in.x, p_in.y, p_in.z):
		return {"hit": true, "voxel": cell, "normal": dda_normal,
			"position": origin + d * t_in, "surface_normal": Vector3(dda_normal)}
	var place_n := Vector3i.UP if ShapeCodec.anchor(m) == ShapeCodec.ANCHOR_BOTTOM else Vector3i.DOWN
	var p0 := origin - base
	for tri: Dictionary in ShapeCodec.surface_tris(m):
		var pn: Vector3 = tri["normal"]
		var denom := d.dot(pn)
		if absf(denom) < 1e-9:
			continue                                   # ray parallel to the surface plane
		var th := (Vector3(tri["v0"]) - p0).dot(pn) / denom
		if th < t_in - _EPS or th > t_out + _EPS:
			continue                                   # plane hit outside this cell's ray span
		var hp := p0 + d * th
		if _point_in_tri_xz(hp, tri["v0"], tri["v1"], tri["v2"]):
			return {"hit": true, "voxel": cell, "normal": place_n,
				"position": origin + d * th, "surface_normal": pn}
	return {}

## True if the XZ projection of point `p` lies inside triangle (a, b, c) — the surface
## is a single-valued height field over XZ, so XZ containment is exact. Barycentric.
func _point_in_tri_xz(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var v0x := c.x - a.x
	var v0z := c.z - a.z
	var v1x := b.x - a.x
	var v1z := b.z - a.z
	var v2x := p.x - a.x
	var v2z := p.z - a.z
	var d00 := v0x * v0x + v0z * v0z
	var d01 := v0x * v1x + v0z * v1z
	var d11 := v1x * v1x + v1z * v1z
	var d20 := v2x * v0x + v2z * v0z
	var d21 := v2x * v1x + v2z * v1z
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 1e-12:
		return false                                   # degenerate triangle (no XZ area)
	var u := (d11 * d20 - d01 * d21) / denom
	var vv := (d00 * d21 - d01 * d20) / denom
	return u >= -_EPS and vv >= -_EPS and u + vv <= 1.0 + _EPS

# Internal alias kept for the collapse pass + DDA; delegates to the composed
# public query (edit overlay first, else generated terrain + trees), so removed
# cells are air and placed/tree cells are solid ray/collapse targets.
func _cell_solid(cell: Vector3i) -> bool:
	return cell_solid(cell)

## Render-only face-cull composition (INTEGRATION-DECISIONS §3): does the neighbour
## whose PACKED value is `nb_value` occlude the shared face of a cell in cull-group
## `my_group` (the viewed material's `transparency_index_of`)? True iff BOTH:
##   (1) the neighbour's MATERIAL occludes — it is solid AND its transparency index
##       is ≤ my_group (the transparency-index rule: an opaque neighbour always
##       occludes; you see THROUGH a more-transparent one, e.g. stone behind glass);
##   (2) its facing side profile fully covers the shared face (`face` = the
##       neighbour-direction index; modifier 0 ⇒ trivially full — today's fast path).
## Static/pure (no world state). For the current all-opaque, full-cube world this is
## exactly `cell_solid(neighbour)`, so it ships as the SEAM P3's translucent
## materials (glass/water) fill in — the fallback mesher's cull test is deliberately
## left on `cell_solid` until then (see chunk_mesher._emit_cube) to guarantee the
## byte-identical visual gate; the module path's culling is config (transparency_index),
## unchanged.
static func occludes_face(nb_value: int, my_group: int, face: int = 0) -> bool:
	var nb_mat := CellCodec.mat(nb_value)
	if BlockCatalog.solidity_of(nb_mat) < 0.5:
		return false                                   # air / water / lava never occlude
	if BlockCatalog.transparency_index_of(nb_mat) > my_group:
		return false                                   # see through a more-transparent neighbour
	return ShapeCodec.side_profile_full(CellCodec.modifier(nb_value), face)

# Distance along one axis to the first integer boundary in the ray's direction.
static func _first_cross(o: float, dir: float) -> float:
	if dir == 0.0:
		return INF
	var cell := floorf(o)
	if dir > 0.0:
		return (cell + 1.0 - o) / dir
	return (o - cell) / -dir
