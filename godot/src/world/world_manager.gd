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

# FP-M1c Planet Assembly pool policy (docs/COSMOS-FP-M1-DESIGN.md §4.3). Amortization throttle (≤1 spawn AND ≤1
# retire per POOL_SPAWN_INTERVAL_S) + the pool-miss counter (a re-designation crossing whose destination was not
# yet pooled falls back to the FP-S1 teardown — must be ~0 in a normal walk; the gate asserts it). All dormant
# unless CubeSphere.FP_M1_POOL. Wall-clock (Time.get_ticks_msec) so it works both live and in headless soaks.
var _last_pool_spawn_ms := -100000
var _last_pool_retire_ms := -100000
var _pool_miss_count := 0             # re-designation POOL-MISS fallbacks (gate: 0 in a normal walk)
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
var _last_player_pos: Vector3 = Vector3.ZERO
var _have_player_pos: bool = false
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
# Sparse per-joint reinforcement (glue/weld/cement; STRUCTURAL-INTEGRITY §4.2/§7):
# canonical key Vector4i(min_cell.x, .y, .z, axis) -> reinforcement id. Lives
# OUTSIDE the four cell axes (it is per-FACE, not per-cell). The structural solver
# reads it via `joint_mod`; breaking a block leaves stale entries harmless (a joint
# with a missing cell is never queried).
var _joint_mods: Dictionary = {}      # Vector4i -> int reinforcement id

func _ready() -> void:
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
	# Far-distance terrain layer (LOD-DESIGN): render-only, collision-free, voxel-worker-free —
	# part of "the world" WorldManager owns. Path-agnostic (it reads only TerrainConfig/BlockCatalog/
	# ClimateModel), so it runs identically over the module world, the GDScript fallback and headless.
	# Gated on the single ENABLED const: false → no node, today's behaviour bit-for-bit.
	# COSMOS FACETED (§5.2): replace FarTerrain (the flat/curved global-index heightmap — a giant misplaced
	# sheet under a single facet) with the facet far ring: the whole planet rendered around the active facet.
	if CubeSphere.FACETED and FacetFarRing.ENABLED:
		_facet_ring = FacetFarRing.new()
		_facet_ring.name = "FacetFarRing"
		add_child(_facet_ring)
		_facet_ring.setup(TerrainConfig.active_facet())
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

	path_selected.emit(using_module)
	print("[WorldManager] rendering path: ",
		"godot_voxel module" if using_module else "GDScript fallback")

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

## Step the dormant-by-default snowfall sim on the MAIN thread once the player position is known. It is a
## no-op with no player (headless verify drives the system directly) or while the prewarm keeps the player
## frozen (update_streaming — the only thing that sets _have_player_pos — is not called until unfrozen).
func _process(delta: float) -> void:
	if _snowfall != null and _have_player_pos:
		var t_snow := Time.get_ticks_usec()   # T2f: attribute the snowfall fixed-step spike
		_snowfall.process(delta, _last_player_pos)
		_snow_us_max = maxi(_snow_us_max, Time.get_ticks_usec() - t_snow)
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
	box.size = Vector3(GRAV_BOX_TANGENTIAL, GRAV_BOX_VERTICAL, GRAV_BOX_TANGENTIAL)
	cs.shape = box
	# Offset the box over the facet's PATCH: the facet-centre lattice cell (T_fid's origin is the lattice ORIGIN, far
	# from the patch via the decorrelation offset O). In the Area's local (lattice) frame +Y is the facet up.
	var centre := FacetAtlas.centre_cell(fid)
	cs.position = Vector3(float(centre.x), 0.0, float(centre.y))
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
	# Latch the latest player position so _process can step the snowfall sim on the main thread. This is
	# also the gate that keeps the sim inert during the frozen prewarm (this is not called while frozen).
	_last_player_pos = player_pos
	_have_player_pos = true
	# COSMOS SEAMLESS-SCALES C3: schedule the skin tiles around the player (nearest-first, evict-farthest,
	# 8 MB-capped). player_pos is in the active facet lattice (the frame the pool works in). Candidate
	# facets = active + live-pool neighbours. No-op unless FP_SKIN_TIER created the node.
	if _skin != null:
		# COSMOS SEAMLESS-SCALES C3 (skin overdraw fix): hand the skin a coverage Callable so it can drop
		# tiles that sit wholly behind the CONFIRMED-meshed near voxels (pure fill overdraw). Routed to
		# module_world.skin_near_meshed (godot_voxel is_area_meshed); an invalid Callable on the fallback /
		# no-module path leaves the skin's skip inert (byte-identical, renders every in-range tile).
		var cover_query := Callable()
		if using_module and _module_world != null and _module_world.has_method("skin_near_meshed"):
			cover_query = Callable(_module_world, "skin_near_meshed")
		_skin.call("update", TerrainConfig.active_facet(), player_pos, _skin_candidate_fids(), cover_query)
	# FP-M1c (§4.3): drive the neighbour pool — spawn a facet when the player's own-side ridge distance drops
	# below D_WARM, retire it past D_RETIRE (+ MIN_LIVE_S), ≤1 op/s, hard cap 1+4. Dormant unless FP_M1_POOL.
	if CubeSphere.FACETED and CubeSphere.FP_M1_POOL and _module_world != null:
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
		return bool(_module_world.call("area_meshed", center, Vector3(40.0, 32.0, 40.0)))
	return true                                     # fallback path / no module → no terrain-format hold

# --- terrain editing (block breaking + placing) --------------------------------

## THE composed cell query (VOXEL-DATA-STRUCTURE §7.1): edit overlay first, else
## generated terrain+trees. Returns the full PACKED cell value (material |
## modifier<<16 | state<<32); material/modifier/state are bit-projections of this
## one int, so they cannot desync. There is no second lookup that could disagree.
func cell_value_at(cell: Vector3i) -> int:
	var e: int = _edits.get(_edit_key(cell), -1)
	if e >= 0:
		return _overlay_window_modifier(cell, e)    # overlay: de-canon the directional modifier into the window frame (§6.4)
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
func _translate_active(src: Dictionary) -> Dictionary:
	var out := {}
	var active := TerrainConfig.active_facet()
	for k in src.keys():
		if FacetAtlas.edit_key_fid(k) != active:
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
	# COSMOS-FRAME-ORIENTATION §6.4: store the directional modifier in its CANONICAL (true-face) frame so
	# it survives a flip; PAINT the window-frame value (the current render). No-op for a full cube.
	_edits[ek] = _overlay_canon_modifier(cell, packed)
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
	if _edits.erase(_edit_key(cell)):
		_paint_cell(cell, cell_value_at(cell))

## ONE debounced ground rebuild for the snowfall sim, run at a step's end iff a write happened (§4.3.5).
## The collider's own debounce coalesces further, and its loose-body gate means it does zero work unless a
## body is actually nearby — a settled pile near the player costs nothing.
func sim_ground_rebuild() -> void:
	if _ground != null:
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
## COSMOS FACETED §6.1 — the crossing handoff. When the player walks past an active-facet ridge (signed own_dist
## < −HYST, one-sided so jitter can't double-fire), re-frame them onto the neighbour facet: switch the active
## facet and return the f64-EXACT reframed position + the dihedral yaw twist for Player.apply_reframe. FP3a: the
## reframe + active-facet switch (the correctness core, gated by cross-and-return byte-identity). FP3b adds the
## module restream (M4 cover), the far-ring re-placement (rigid, no regen), and debris re-frame. {} = no crossing.
func maybe_cross_facet(player_pos: Vector3) -> Dictionary:
	if not CubeSphere.FACETED:
		return {}
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return {}
	# FP-S1(c): cooldown — after a committed crossing, suppress the next FACET_CROSS_COOLDOWN calls so a crossing
	# can never re-fire immediately (ridge-jitter / residual oscillation). A genuine sequential crossing traverses
	# the whole facet (many ticks ≫ cooldown), so this never blocks a legitimate crossing.
	if _cross_cooldown > 0:
		_cross_cooldown -= 1
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
				continue
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
				# FP-M1c: RE-DESIGNATION crossing -- ONE PlanetRoot transform write + view rebalance inside redesignate(),
				# NO teardown/restream/new generator. The old active field persists rotated (no removed frame). Re-place
				# the far ring + refresh its live-pool exclusion (deferred/rigid; no synchronous regen).
				var _far_t0 := Time.get_ticks_usec()
				if _facet_ring != null:
					_facet_ring.set_active(to)
					_facet_ring_sync_exclusion()
				if _skin != null:
					_skin.call("set_active", to)
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
				_flip_settling = true
				_restream()
			# COSMOS FP-FIXED-FRAME §2.2 steps 4–8 (Phase 2 keystone) — the crossing is now pure O(1) bookkeeping.
			# redesignate() SKIPPED the PlanetRoot transform write (module_world, flag-gated), so NO
			# NOTIFICATION_TRANSFORM_CHANGED / per-mesh-block re-place fired (the 200–772 ms spike is gone). Instead we
			# re-place ONLY the ~10 NON-terrain children by flipping the ActiveFrame node from T_from to T_to:
			if _fixed_frame_on():
				# 4. ActiveFrame → T_to (the new active facet's TRUE absolute transform, folded through the re-anchor
				#    offset). Its children (player, collider, debris) keep their LATTICE locals; their globals follow to
				#    planet-absolute space. O(1) — never terrain.
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
	return {}

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

func _manage_facet_pool(player_pos: Vector3) -> void:
	if not _module_world.has_method("pool_spawn"):
		return
	var active := TerrainConfig.active_facet()
	if active < 0:
		return
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
	# CROSSING-FASTGEN obs-2 fix (3): pass the measured player speed so the imminent-select D_WARM shell leads with
	# velocity (vel_lead ≡ 0 with FP_VEL_PREDICT off → the shell is exactly POOL_D_WARM, byte-identical).
	var targets := z1_live_targets(want, off_surface, live_now, _player_speed)
	# CONTROLLER-FIX §P3c/§P3d: publish the imminent-ridge fid (targets[0], the incumbent-hysteresis winner) to the module
	# so its pool-ramp slot is pace-floored, its LOD stays budgeted through relief mode, and demote never coarsens it.
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
	# SPAWN (promote LOD → live): the highest-priority target not yet live, iff the controller admits it AND we are below
	# the Z1 live cap. One spawn per SPAWN_INTERVAL_S (amortized). W1 — targets[0] is the IMMINENT ridge (the one we are
	# committed to crossing); it is EXEMPT from the raw vox_gen backlog gate (while walking vox_gen naturally sits
	# 1500-2800, which would otherwise suppress the crossing promote → a silent fall-back to spawn-at-cross + a pool-miss).
	# It still needs sustained frame HEADROOM (promote_admit_imminent). The 2nd/corner target keeps the FULL backlog gate
	# — the feed-forward throttle applies to that EXTRA generation volume, and its view-ramp pace is throttled regardless.
	if now - _last_pool_spawn_ms >= interval_ms:
		for idx in range(targets.size()):
			var t: int = int(targets[idx])
			if bool(_module_world.call("pool_has", t)):
				continue
			if int(_module_world.call("pool_neighbour_count")) >= CubeSphere.FP2_LIVE_CAP:
				break
			var admitted: bool = promote_admit_imminent(_load_ctrl, float(want.get(t, 1.0e30)), _player_speed) if idx == 0 else promote_admit(_load_ctrl)
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
		for nb in live_now:
			if targets.has(nb):
				continue
			var d: float = want.get(nb, 1.0e30)
			if d > CubeSphere.POOL_D_RETIRE and float(_module_world.call("pool_age_s", nb)) >= CubeSphere.POOL_MIN_LIVE_S:
				if bool(_module_world.call("pool_retire", nb)):
					_last_pool_retire_ms = now
					# C4: do NOT erase _promote_pending here — retire alone would leave the mesher's promote-HOLD set
					# (on_promote) forever, PINNING the held LOD mesh in the cache (no idle/LRU path frees it). Instead let
					# THIS tick's _lod_promote_pass see `not pool_has(nb)` → lod_end_promote(nb) → lift the hold → erase.
					changed = true
					break
	return changed

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
static func z1_live_targets(want: Dictionary, off_surface: bool, live_now: Array, speed: float = 0.0) -> Array:
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
	var excluded: Array = (_module_world.call("pool_neighbour_fids") as Array).duplicate()
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

## T2f (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-consumer main-thread attribution for the telemetry window. Returns
## the MAX single-frame cost (ms) of the snowfall fixed step + the load-controller tick since the last call, then resets
## the accumulators — RemoteBridge samples it once per telemetry window so a 0.5 s snowfall spike is attributed as its own
## number rather than folded anonymously into worst_ms. Read-only w.r.t. gameplay; the timers are passive ticks_usec reads.
func take_perf_attrib() -> Dictionary:
	var out := {
		"snow_ms": snappedf(float(_snow_us_max) / 1000.0, 0.01),
		"ctrl_ms": snappedf(float(_ctrl_us_max) / 1000.0, 0.01),
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
	# FP-M1a: FACETED (no chart) — the active facet lattice IS the window, so keep this facet's edits and
	# index them directly by their unpacked cell (x, z) / y high-water mark.
	if CubeSphere.FACETED and _chart == null:
		var active := TerrainConfig.active_facet()
		for k in _edits.keys():
			if FacetAtlas.edit_key_fid(k) != active:
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
		_write_cell(region_origin + local, packed, chunk.meta_at(idx))

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
func surface_y(x: float, z: float) -> float:
	return float(effective_height(int(floor(x)), int(floor(z))) + 1)

## The y the player should stand at in column (x, z) given their current feet
## height. Plain, NO-CLIMB floor: scan DOWN from the feet for the first solid block
## that has AIR directly above it (the actual standable surface) and stand on its
## top. Crucially it does NOT pop the player up to the column top when the feet cell
## is buried — walling into a hillside must not teleport the player onto the hilltop.
## Horizontal movement into terrain is now stopped by blocked() (the player queries
## it per-axis), so the feet are always at or just above an air-topped surface and a
## valid floor is always found; the scan honours dug shafts/tunnels below as well.
func floor_under(x: float, z: float, feet_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)   # in-cell footprint (ignored by full cubes; used by P5 shapes)
	var fz := z - float(zi)
	# Start at the feet directly (NO clamp to the noise top): players stand on trees
	# and placed towers ABOVE the heightmap, and clamping down would teleport them
	# off. Scan length is bounded by the fall distance — cheap.
	var start := int(floor(feet_y + 0.5))
	var y := start
	# Merged contract (INTEGRATION-DECISIONS §3): the per-cell test is `_occ_span`, so
	# non-solid materials (water) yield the empty span and are scanned THROUGH to the
	# seafloor, while a solid cell yields its filled interval — the floor is the top of
	# the first occupied cell that has an empty span directly above (its top = span.y;
	# 1.0 for a full cube ⇒ float(y+1), byte-identical to the old solid/air-above test).
	while y > -1024:
		var here := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if here != Vector2.ZERO and _occ_span(cell_value_at(Vector3i(xi, y + 1, zi)), fx, fz) == Vector2.ZERO:
			return float(y) + here.y
		y -= 1
	return float(effective_height(xi, zi) + 1)

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
func blocked(x: float, z: float, feet_y: float) -> bool:
	# COSMOS FACETED §5.3: the ridge wall. Until the FP3 handoff lets the player cross onto the neighbour, an
	# invisible wall sits just inside each active-facet ridge plane, so the player can stand on the own-side of
	# every junction cell but not walk past P into the masked void. One own_dist test per ≤4 seams.
	if CubeSphere.FACETED:
		var fid := TerrainConfig.active_facet()
		if fid >= 0:
			for slot in 4:
				if FacetAtlas.own_dist(fid, slot, x, feet_y, z) < FACET_WALL_EPS:
					return true
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	# Standable height at the target column, allowing an auto-step up to STEP_MAX.
	var top := floor_under(x, z, feet_y + STEP_MAX)
	if top - feet_y > STEP_MAX:
		return true                                    # rise too big → wall (a full cube's 1.0 always is)
	# Headroom above the (possibly auto-stepped) floor: the body must not clip a solid
	# cell in (top, top + body height) at this footprint.
	return not _headroom_clear(xi, zi, fx, fz, top)

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
func ceiling_scan(x: float, z: float, from_head_y: float, to_head_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	var y := int(floor(from_head_y))
	var y_hi := int(floor(to_head_y))
	while y <= y_hi:
		var sp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if sp != Vector2.ZERO:
			var occ_lo := float(y) + sp.x
			if occ_lo >= from_head_y - _EPS:
				return occ_lo
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
func aimed_voxel(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
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
