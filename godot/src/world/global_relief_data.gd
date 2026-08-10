class_name GlobalReliefData
extends RefCounted
## docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md §3.2/§3.1 (task #99, STAGE 1: G2 `FP_GLOBAL_RELIEF_DATA` + G1a
## `FP_SKIN_RELIEF_SHADE`). Fixes "flat from orbit": the FacetFarRing shell shades by the RADIAL normal only
## (zero slope contrast) and its own node grid (CELLS=4, ~104-block cells) under-samples the ~1250-block
## mountain wavelength — so even the relief it DOES emit reads flat at distance. G3 (a view-dependent relief
## MESH built from this data) and G1b (a live sun-tracking normal map) are LATER passes — this class ships only
## the two SAFE layers: the DATA (G2) and a sun-agnostic shading DERIVATIVE of it (G1a).
##
## G2 — the bounded whole-planet coarse height DEM: i16 relief (blocks) at `CELLS`(32) cells/facet edge (33²
## nodes ≈ 13-block horizontal pitch), one array indexed `fid * NODES_PER_FACET + j*NODES_PER_EDGE + i`.
## `3456 facets × 33² nodes × 2 B ≈ 7.5 MB` (doc §3.2/§4), always-resident CPU-only once baked (no GPU copy —
## consumed by mesh/shade builds, never sampled by the shader directly). Baked facet-by-facet via
## `VoxelGeneratorCosmos.bake_smooth_tile(corner_dirs, r_datum, CELLS)` (patch 0012, resolution-agnostic, already
## engine-resident — NO new C++) with a GDScript `FarDensity.node_at` fallback when the compiled class is absent
## (the same "module missing ⇒ GDScript oracle, same law" degrade this codebase uses everywhere, e.g.
## `FacetSkinTier.gd_sample`). Both paths derive from the ONE `profile_at_dir` law through the SAME canon corner
## dirs (`FacetAtlas.facet_corner_dirs`) the skin/shell/V2 already weld through, so G2 heights agree with them
## BY CONSTRUCTION (G-GP-DATA-EQ).
##
## G1a — a SUN-AGNOSTIC hillshade/AO derivative of G2, computed in the SAME bake pass (central-difference slope
## magnitude over the just-baked height grid; NO `sun_dir` parameter anywhere in its signature, so it is
## STRUCTURALLY incapable of reproducing `FP_SMOOTH_V2_LIT`'s wrong-sun-shadow failure class — see
## `hillshade_from_heights`). STAGE-1 SCOPING NOTE (disclosed to team-lead): the design doc specifies a FINER
## 64²/facet skin-resolution shade layer (+13.5 MB) meant for GPU texture compositing into the shell shader；
## this pass instead stores shade at G2's OWN 33²/facet node resolution (+~3.6 MB, well inside the doc's 40 MB
## cap) as pure DATA + a gate-verifiable pure function. The GPU-texture/shader-ALBEDO compositing wiring itself
## (touching ~7 separate shell vertex-colour bake sites across LOD tiers, none of which this host's headless
## RenderingServer can visually verify — "LIVE-PROBE-REQUIRED" per this project's own established caveat, see
## `FP_SMOOTH_V2_LIT`'s doc comment) is NOT wired this pass; the data/bake/ledger/sun-agnostic properties are
## fully real and gated (G-GP-OFF/DATA-EQ/BYTES/PACE below). A follow-up can splice it into the shell's vertex-
## colour bake exactly like `FarPalette.color_for` already is.
##
## Filled by the SAME governed pacer discipline as `FP_BG_PREBAKE` (`facet_tex_baker.gd`'s
## `_update_band_parallel`): `step()` bakes AT MOST ONE facet per call, only when the caller's measured real
## frame time is under `CubeSphere.BG_FRAME_BUDGET_MS`, nearest-to-`emit_axis` first (mirrors
## `FacetTexBaker._next_fine_fid`'s view-cone-first scan, `facet_tex_baker.gd:1708`) then a linear sweep once the
## view cone is exhausted — never a call that dispatches more than one bake regardless of remaining budget (the
## rate-cap lesson `FP_BG_PREBAKE`'s own doc cites). `bake_smooth_tile` is "~ms/facet" (doc §5), so this
## completes well inside the texture prebake's own sweep — no new pacer machinery, no WorkerThreadPool (the bake
## is fast enough to run synchronously on main under the SAME frame-budget gate the texture baker already uses).
##
## Off (`FP_GLOBAL_RELIEF_DATA == false`) ⇒ `setup()` never allocates the arrays, `step()`/`bake_facet()` are
## no-ops (empty-array early return) ⇒ byte-identical (FLAT verify_feature.gd 6042/0). Gate: verify_far_geometry.gd
## (G-GP-OFF/G-GP-DATA-EQ/G-GP-BYTES/G-GP-PACE + G1a's sun-agnostic invariant).

const CELLS := 32                                    # cells/facet edge (doc §3.2's "knee": resolves the ~1250-block
                                                       # mountain wavelength ~96×; 64 would be sharper but beyond what
                                                       # mid-altitude viewing distinguishes)
const NODES_PER_EDGE := CELLS + 1                     # 33
const NODES_PER_FACET := NODES_PER_EDGE * NODES_PER_EDGE   # 1089

## G1a hillshade law (sun-agnostic slope-magnitude darkening, doc §3.1 "shade = f(|∇h|, curvature)"): a simple
## monotone falloff in the local gradient magnitude, floored so nothing goes fully black. No directional term —
## the signature of `hillshade_from_heights` below never takes a sun_dir, so it CANNOT encode a wrong-sun shadow.
const SHADE_K := 0.35
const SHADE_FLOOR := 0.35

## GDScript has no PackedInt16Array — heights are stored as a raw PackedByteArray, 2 bytes/node (little-endian
## signed 16-bit via encode_s16/decode_s16), which is the SAME byte footprint the doc's "i16" budget assumes
## (3456 × 33² × 2 B ≈ 7.5 MB) — a real i16 packing, not a wider int padded out.
var _heights: PackedByteArray = PackedByteArray()     # facet_count()*NODES_PER_FACET*2 bytes; empty ⇒ not set up
var _shade: PackedByteArray = PackedByteArray()       # facet_count()*NODES_PER_FACET, L8 (0..255); empty unless G1a on
var _baked: PackedByteArray = PackedByteArray()       # facet_count() bytes; 1 = this facet's nodes are filled
var _baked_count := 0
var _cursor := 0                                      # linear-sweep fallback cursor (once the view cone empties)
var _cpp_gen: Object = null                            # frozen VoxelGeneratorCosmos (any fid — facet-independent); null ⇒ GDScript fallback

## FP_DEM_DEFER (docs/COSMOS-STREAM-PARALLEL-DESIGN.md Phase A) — the fresh-reload fix. All three stay EMPTY/false with
## the flag off (setup() only builds them under FP_DEM_DEFER), so the shipped gated pacer below is byte-identical.
var _centre_dirs: PackedVector3Array = PackedVector3Array()   # setup-time per-facet centre dirs (n × 12 B ≈ 41 KB): the
                                                              # alloc-free basis for the nearest-first scan, replacing the
                                                              # per-call allocating `_centre_dir(fid)` used by `_next_unbaked`.
var _want: Dictionary = {}            # fid -> true: the DEMAND want-list the far ring's shade pull registers (post-settle,
                                       # on-surface) — served instead of a blind O(3456) whole-planet sweep.
var _settled := false                 # has the near view meshed? until WorldManager latches mark_settled(), step() bakes nothing.

## Allocate the always-resident arrays (facet_count() from FacetAtlas — MULTI_BODY-aware, matches every other
## whole-planet ledger in this codebase). No-op with the flag off ⇒ every array stays empty ⇒ every accessor
## below degrades to its "not ready" default ⇒ byte-identical.
func setup() -> void:
	if not CubeSphere.FP_GLOBAL_RELIEF_DATA:
		return
	var n := FacetAtlas.facet_count()
	_heights = PackedByteArray(); _heights.resize(n * NODES_PER_FACET * 2); _heights.fill(0)
	_baked = PackedByteArray(); _baked.resize(n); _baked.fill(0)
	_baked_count = 0
	_cursor = 0
	if CubeSphere.FP_SKIN_RELIEF_SHADE:
		_shade = PackedByteArray(); _shade.resize(n * NODES_PER_FACET); _shade.fill(255)
	if CubeSphere.FP_DEM_DEFER:
		# FP_DEM_DEFER: precompute every facet's centre dir ONCE (the allocating `_centre_dir` scan the shipped
		# `_next_unbaked` runs per admitted step is the main-thread cost this kills). Built only under the flag ⇒
		# no new resident bytes with it off (byte-off). _want/_settled reset for a fresh load.
		_centre_dirs = PackedVector3Array(); _centre_dirs.resize(n)
		for fid in range(n):
			_centre_dirs[fid] = _centre_dir(fid)
		_want = {}
		_settled = false
	if ClassDB.class_exists("VoxelGeneratorCosmos"):
		_cpp_gen = FacetSkinTier._build_cpp_gen(0)   # facet-independent config; any fid bakes any facet's tile

func is_ready() -> bool:
	return not _heights.is_empty()

func facet_count() -> int:
	return _baked.size()

func is_baked(fid: int) -> bool:
	return fid >= 0 and fid < _baked.size() and _baked[fid] == 1

func baked_count() -> int:
	return _baked_count

## Height (blocks) at node (i,j) of facet fid, i,j ∈ [0, CELLS]. 0 if not ready / out of range (never baked yet).
func height_at(fid: int, i: int, j: int) -> int:
	if _heights.is_empty() or fid < 0 or fid >= _baked.size() or i < 0 or i > CELLS or j < 0 or j > CELLS:
		return 0
	return _heights.decode_s16((fid * NODES_PER_FACET + j * NODES_PER_EDGE + i) * 2)

## FP_ORBIT_RELIEF (docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md §1.2): a facet's WHOLE height grid as one flat,
## immutable snapshot (row-major j*NODES_PER_EDGE+i), for the caller to hand to a WorkerThreadPool tile build.
## MUST be called on the MAIN THREAD, before dispatch — `_heights` is an ONGOING-write array (`bake_facet` keeps
## filling it live during gameplay, unlike `FacetAtlas`'s write-once-then-read-only atlas tables), so a worker
## reading it directly would be a data race; this copies the one facet's 1089 values into a private
## `PackedInt32Array` the worker can safely own. All-zero (the same neutral default `height_at` returns) if the
## facet isn't baked yet. Cheap: 1089 `decode_s16` reads — but `FacetOrbitRelief` was calling this on EVERY
## dispatch even for an already-baked (therefore IMMUTABLE) facet, redoing the same 1089 reads repeatedly.
## PERF FIX WS1d (live A/B follow-up): cache the snapshot PER FID once the facet is truly baked (`bake_facet`
## never re-bakes an already-baked facet — idempotent no-op — so a baked facet's heights can never change again,
## making this cache permanently valid; a call BEFORE baking is deliberately left uncached, so a LATER real bake
## is still correctly picked up next call). Main-thread only (matches every other caller of this function).
var _height_grid_cache: Dictionary = {}   # fid -> PackedInt32Array, lazily cached once baked
func height_grid(fid: int) -> PackedInt32Array:
	if _height_grid_cache.has(fid):
		return _height_grid_cache[fid]
	var out := PackedInt32Array()
	out.resize(NODES_PER_FACET)
	for j in range(NODES_PER_EDGE):
		for i in range(NODES_PER_EDGE):
			out[j * NODES_PER_EDGE + i] = height_at(fid, i, j)
	if is_baked(fid):
		_height_grid_cache[fid] = out
	return out

## G1a shade [0,1] at the same node grid. 1.0 (no darkening) if not ready/baked/flag-off — a safe neutral default,
## never a black hole where data hasn't landed yet.
func shade_at(fid: int, i: int, j: int) -> float:
	if not CubeSphere.FP_SKIN_RELIEF_SHADE or _shade.is_empty() or fid < 0 or fid >= _baked.size():
		return 1.0
	if i < 0 or i > CELLS or j < 0 or j > CELLS:
		return 1.0
	return float(_shade[fid * NODES_PER_FACET + j * NODES_PER_EDGE + i]) / 255.0

## The GDScript oracle for ONE node — `FarDensity.node_at` at (s,t) = (i/CELLS, j/CELLS), the SAME law
## `bake_smooth_tile` mirrors in C++ (proven byte-equal historically, gate G-CSB-EQ). Used both as the
## fallback bake path (module absent) and as `verify_far_geometry.gd`'s independent DATA-EQ reference.
static func node_height_gd(corner_dirs: PackedFloat64Array, r_datum: float, i: int, j: int) -> int:
	var node: Dictionary = FarDensity.node_at(corner_dirs, r_datum, float(i) / float(CELLS), float(j) / float(CELLS))
	return int(node["g"])

## The facet edge length in BLOCKS (from the real canon corner span) — the node pitch's basis (pitch = edge/CELLS),
## used only by the G1a slope derivative (a hillshade "how many blocks per node" scale, not a weld-critical value).
static func _edge_length_blocks(corner_dirs: PackedFloat64Array, r_datum: float) -> float:
	var dx := corner_dirs[3] - corner_dirs[0]
	var dy := corner_dirs[4] - corner_dirs[1]
	var dz := corner_dirs[5] - corner_dirs[2]
	return sqrt(dx * dx + dy * dy + dz * dz) * r_datum

## PURE sun-agnostic hillshade from a flat height grid (no fid/corner_dirs dependence — a gate can call this
## directly on a synthetic grid). `heights` is `(edge+1)²` int16-ish ints, row-major (j*edge1+i); `pitch_blocks`
## is the real horizontal spacing between adjacent nodes. Central differences (one-sided clamped at the border);
## NEVER takes a sun_dir — this is the structural guarantee behind G1a's "sun-agnostic" property, not a numeric
## coincidence: the failure class this must avoid (FP_SMOOTH_V2_LIT's wrong-sun shadows) requires a directional
## term to exist at all, and none does here.
static func hillshade_from_heights(heights: PackedInt32Array, edge: int, i: int, j: int, pitch_blocks: float) -> float:
	if pitch_blocks <= 0.0:
		return 1.0
	var il := maxi(i - 1, 0); var ir := mini(i + 1, edge)
	var jd := maxi(j - 1, 0); var ju := mini(j + 1, edge)
	var span_x := float(ir - il)
	var span_z := float(ju - jd)
	var dx := 0.0
	var dz := 0.0
	if span_x > 0.0:
		dx = float(heights[j * (edge + 1) + ir] - heights[j * (edge + 1) + il]) / (pitch_blocks * span_x)
	if span_z > 0.0:
		dz = float(heights[ju * (edge + 1) + i] - heights[jd * (edge + 1) + i]) / (pitch_blocks * span_z)
	var grad := sqrt(dx * dx + dz * dz)
	return clampf(1.0 - SHADE_K * grad, SHADE_FLOOR, 1.0)

## Bake ONE facet: fills `_heights[fid]` (native `bake_smooth_tile` if the module is present, else the GDScript
## `FarDensity.node_at` loop — same law, either way) and, under FP_SKIN_RELIEF_SHADE, derives `_shade[fid]` from
## the just-baked heights via `hillshade_from_heights`. Idempotent (no-op + false if already baked / not set up).
func bake_facet(fid: int) -> bool:
	if _heights.is_empty() or is_baked(fid):
		return false
	var corner_dirs := FacetAtlas.facet_corner_dirs(fid)
	var r_datum := FacetAtlas.r_of(fid)
	var g_vals := PackedInt32Array()
	var used_cpp := false
	if _cpp_gen != null:
		var baked: Dictionary = _cpp_gen.call("bake_smooth_tile", corner_dirs, r_datum, CELLS)
		if baked.has("g") and (baked["g"] as PackedInt32Array).size() == NODES_PER_FACET:
			g_vals = baked["g"]
			used_cpp = true
	if not used_cpp:
		g_vals.resize(NODES_PER_FACET)
		for j in range(NODES_PER_EDGE):
			for i in range(NODES_PER_EDGE):
				g_vals[j * NODES_PER_EDGE + i] = node_height_gd(corner_dirs, r_datum, i, j)
	var base := fid * NODES_PER_FACET
	for k in range(NODES_PER_FACET):
		_heights.encode_s16((base + k) * 2, clampi(g_vals[k], -32768, 32767))
	if CubeSphere.FP_SKIN_RELIEF_SHADE and not _shade.is_empty():
		var pitch := _edge_length_blocks(corner_dirs, r_datum) / float(CELLS)
		for j in range(NODES_PER_EDGE):
			for i in range(NODES_PER_EDGE):
				var s := hillshade_from_heights(g_vals, CELLS, i, j, pitch)
				_shade[base + j * NODES_PER_EDGE + i] = clampi(int(round(s * 255.0)), 0, 255)
	_baked[fid] = 1
	_baked_count += 1
	return true

## The facet centre direction (unit) — average of its 4 canon corner dirs, mirrors `FacetTexBaker._ensure_centre_pack`'s
## convention (used only for the view-cone-first sweep ordering below, never weld-critical).
func _centre_dir(fid: int) -> Vector3:
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var s := Vector3.ZERO
	for ci in range(4):
		s += Vector3(cd[ci * 3], cd[ci * 3 + 1], cd[ci * 3 + 2])
	return s.normalized()

## Nearest-to-`emit_axis` unbaked facet (mirrors `FacetTexBaker._next_fine_fid`'s pattern, `facet_tex_baker.gd:1708`);
## falls back to a linear sweep from `_cursor` once no axis is given / the whole planet is already covered by view.
## -1 once every facet is baked.
func _next_unbaked(emit_axis: Array) -> int:
	var n := _baked.size()
	if emit_axis.size() == 3:
		var ax := float(emit_axis[0]); var ay := float(emit_axis[1]); var az := float(emit_axis[2])
		if ax * ax + ay * ay + az * az > 0.5:
			var best := -1
			var best_d := -2.0
			for fid in range(n):
				if _baked[fid] == 1:
					continue
				var cd := _centre_dir(fid)
				var dt := cd.x * ax + cd.y * ay + cd.z * az
				if dt > best_d:
					best_d = dt; best = fid
			if best >= 0:
				return best
	for k in range(n):
		var fid := (_cursor + k) % n
		if _baked[fid] == 0:
			_cursor = (fid + 1) % n
			return fid
	return -1

## FP_DEM_DEFER (docs/COSMOS-STREAM-PARALLEL-DESIGN.md Phase A): WorldManager latches this ON once the near view has
## MESHED (`initial_view_meshed`). Until then `step()` bakes NOTHING under the flag — the whole-planet DEM is
## deferred out of the fresh-reload window (its only on-surface consumer, the far-ring shade multiply, self-degrades
## to 1.0 while unbaked, so this is visually free). No-op / irrelevant with the flag off.
func mark_settled() -> void:
	_settled = true

func is_settled() -> bool:
	return _settled

## FP_DEM_DEFER: the far ring's colour bake registers a DEMAND here (`facet_far_ring.gd`'s shade-multiply pull site)
## whenever it builds a facet's cache while that facet's DEM isn't baked yet — so the deferred pacer serves exactly
## the view-touched facets nearest-first instead of a blind whole-planet sweep. No-op off the flag / already baked /
## out of range (byte-off: `_want` never populates with the flag off, so `_next_wanted` is unreachable).
func request(fid: int) -> void:
	if not CubeSphere.FP_DEM_DEFER:
		return
	if fid < 0 or fid >= _baked.size() or _baked[fid] == 1:
		return
	_want[fid] = true

## FP_DEM_DEFER telemetry/gate: how many demanded facets are still pending (unbaked).
func want_count() -> int:
	return _want.size()

## FP_DEM_DEFER: the demanded, still-unbaked facet nearest `emit_axis` (alloc-free — reads the setup-time centre-dir
## table, never `_centre_dir(fid)`). Purges already-baked/stale demands as it scans. -1 when the want-list is empty.
func _next_wanted(emit_axis: Array) -> int:
	if _want.is_empty():
		return -1
	var have_axis := false
	var ax := 0.0; var ay := 0.0; var az := 0.0
	if emit_axis.size() == 3 and _centre_dirs.size() == _baked.size():
		ax = float(emit_axis[0]); ay = float(emit_axis[1]); az = float(emit_axis[2])
		have_axis = ax * ax + ay * ay + az * az > 0.5
	var best := -1
	var best_d := -2.0
	var fallback := -1
	for fid in _want.keys():                       # .keys() is a snapshot Array ⇒ safe to erase during the loop
		if fid < 0 or fid >= _baked.size() or _baked[fid] == 1:
			_want.erase(fid)                       # already baked / invalid — drop the demand
			continue
		if fallback < 0:
			fallback = fid
		if have_axis:
			var cd := _centre_dirs[fid]
			var dt := cd.x * ax + cd.y * ay + cd.z * az
			if dt > best_d:
				best_d = dt; best = fid
	return best if best >= 0 else fallback

## FP_DEM_DEFER: alloc-free variant of `_next_unbaked` for the OFF-SURFACE whole-planet sweep — reads the setup-time
## `_centre_dirs` table instead of allocating a fresh `_centre_dir(fid)` per facet (the per-call cost the shipped
## scan pays). Same nearest-`emit_axis`-first-then-linear-cursor ordering. -1 once every facet is baked.
func _next_unbaked_fast(emit_axis: Array) -> int:
	var n := _baked.size()
	if emit_axis.size() == 3 and _centre_dirs.size() == n:
		var ax := float(emit_axis[0]); var ay := float(emit_axis[1]); var az := float(emit_axis[2])
		if ax * ax + ay * ay + az * az > 0.5:
			var best := -1
			var best_d := -2.0
			for fid in range(n):
				if _baked[fid] == 1:
					continue
				var cd := _centre_dirs[fid]
				var dt := cd.x * ax + cd.y * ay + cd.z * az
				if dt > best_d:
					best_d = dt; best = fid
			if best >= 0:
				return best
	for k in range(n):
		var fid := (_cursor + k) % n
		if _baked[fid] == 0:
			_cursor = (fid + 1) % n
			return fid
	return -1

## Governed pacer step (mirrors `FP_BG_PREBAKE`'s `_update_band_parallel` discipline): bakes AT MOST ONE
## not-yet-baked facet, nearest-`emit_axis` first, ONLY when `frame_ms` shows the last frame had headroom.
## `frame_ms` is a REAL measured wall-clock delta from the caller (never `Performance.TIME_PROCESS` — the same
## "invalid on threaded web" discipline `FP_BG_PREBAKE`/`StreamLoadController.LiveSource` already use). Returns
## the fid baked this call, or -1 (nothing dispatched: complete / hot frame / not set up).
## `offsurface` (default true) is consulted ONLY under FP_DEM_DEFER — see `_step_deferred`.
func step(emit_axis: Array, frame_ms: float, offsurface := true) -> int:
	if not CubeSphere.FP_GLOBAL_RELIEF_DATA or _heights.is_empty():
		return -1
	if _baked_count >= _baked.size():
		return -1
	if CubeSphere.FP_DEM_DEFER:
		return _step_deferred(emit_axis, frame_ms, offsurface)
	if frame_ms >= CubeSphere.BG_FRAME_BUDGET_MS:
		return -1
	var fid := _next_unbaked(emit_axis)
	if fid < 0:
		return -1
	return fid if bake_facet(fid) else -1

## FP_DEM_DEFER's step (Phase A, docs/COSMOS-STREAM-PARALLEL-DESIGN.md §4.2): defer + demand-drive + first-call fix.
func _step_deferred(emit_axis: Array, frame_ms: float, offsurface: bool) -> int:
	# FIRST-CALL FIX: require ≥1 real inter-frame sample. `frame_ms == 0` happens ONLY on the boot frame (the
	# `_g2_last_frame_usec == 0` loophole) — the single busiest frame of the load; a real delta is always > 0.
	if frame_ms <= 0.0:
		return -1
	if frame_ms >= CubeSphere.BG_FRAME_BUDGET_MS:
		return -1
	# DEFER: bake nothing until the near view has settled (the fresh-reload window WorldManager gates on).
	if not _settled:
		return -1
	# DEMAND-DRIVEN: serve the fids the far ring's shade pull actually asked for (nearest-first), NOT a blind sweep.
	var fid := _next_wanted(emit_axis)
	if fid < 0 and offsurface:
		# Off-surface the near field is frozen (FP_ALT_REGIME) ⇒ real headroom to fill the rest of the planet for
		# the G3 relief mesh. Alloc-free sweep via the setup-time centre-dir table (never on-surface — no blind sweep
		# competes with the near-field load).
		fid = _next_unbaked_fast(emit_axis)
	if fid < 0:
		return -1
	if bake_facet(fid):
		_want.erase(fid)   # served — clear the demand (harmless no-op if it came from the off-surface sweep)
		return fid
	return -1

## NEVER-OOM ledger: bytes actually resident right now (0 while off/not set up). i16 heights (2B/node) + the
## baked-flag byte array + (under FP_SKIN_RELIEF_SHADE) the L8 shade layer (1B/node).
func resident_bytes() -> int:
	if _heights.is_empty():
		return 0
	var b := _heights.size() + _baked.size()   # _heights is already byte-sized (2 B/node packed via encode_s16)
	if not _shade.is_empty():
		b += _shade.size()
	return b
