class_name FacetLodMesher
extends Node3D
## COSMOS FP-M2b (docs/COSMOS-FP-M2-DESIGN.md §5, §6.2, §7.4) — the LOD-mesh layer that REPLACES the FacetFarRing
## coloured quads for the near rings of facets around the active facet. A child of module_world's PlanetRoot (@
## identity), so a crossing's ONE PlanetRoot.transform write re-places every LOD mesh rigidly (zero rebuild). Owns
## exactly ONE FacetLodBuilder (the M2a off-terrain build primitive — one persistent background Thread, NEVER the
## voxel worker pool). Each covered facet's LOD mesh lives under a LodFacet_<fid> node @ facet_transform(fid); a
## per-tile MeshInstance is placed at Transform3D(Basis.from_scale(ONE·s), tile-lattice-corner) so uniform scale s
## + lattice translation land the megablocks exactly where the live terrain's blocks would (§8 / G-M2-FRAME).
##
## M2b SCOPE (static): tier assignment is a fixed per-ring rule (§13) — ring-1 → ℓ1, ring-2 → ℓ2, ring-3 → ℓ3,
## beyond → the ℓ=∞ coloured quad (still drawn by the FacetFarRing, the universal fallback). The camera-driven SSE
## selector, the request-grant budgeter and the load-adaptive controller are M2c — NOT here. The Z1-hybrid pool
## policy / promote-demote is M2d. Here the ladder pace is immediate; only the NEVER-OOM caps (§6.2/§11) bind.
##
## NEVER-OOM: every cap below is HARD and asserted headless (G-M2-CAPS). Admission is estimate-based + synchronous
## (§1.3 per-tier estimates) so an over-cap request storm can never enqueue past the ceiling; LRU evicts only
## NON-wanted facets (a still-wanted facet degrades its grant one tier instead of evicting another wanted one), and
## an evicted facet drops OUT of covered_fids() so the far-ring quad stays behind it — never a hole. The ridge
## apron (§7.4) is counted in the SAME tri/byte ledgers (bounded ≈ 128 aprons ≈ 65k tris / ≤ 2 MB worst).
##
## Everything here is DEAD unless CubeSphere.FP_M2_LOD (requires FACETED + FP_M1_POOL + the module binary). With
## the flag off the mesher is never created, tick() never runs, and covered_fids() is never consulted → the game
## is byte-identical to FP-M1c (FLAT 6027/0; faceted pool 137/0).

const FLB := preload("res://src/world/facet_lod_builder.gd")

# ---- policy consts (§5 — asserted by verify_fp_m2 G-M2-CAPS) ----
const LOD_MAX_TIER := 3            # shipped tiers ℓ∈{1..3}; the quad is the ℓ=∞ tier (ℓ0 is live-terrain only)
const LOD_APPLY_BUDGET_MS := 2.0   # main-thread per-frame apply budget (never a synchronous whole-facet apply)
const LOD_MAX_FACETS := 64         # HARD cap: facets holding an applied LOD mesh (+ in-flight builds)
const LOD_MAX_TRIS := 3_000_000    # HARD cap: total LOD triangles (meshes + aprons)
const LOD_MAX_BYTES_MB := 96       # HARD cap: CPU-side mesh bytes (§11 ledger; ×1024×1024 below)
const LOD_QUEUE_MAX_JOBS := 16     # tiles queued but not yet building (feed-forward bound; M2c budgeter refines)
const LOD_IDLE_DEMOTE_S := 30.0    # (M2c uses proactively; present here for the const ledger)
const LOD_COVER_RINGS := 3         # STATIC (M2b): cover facet-rings 1..3 with ℓ1/ℓ2/ℓ3; beyond → quad
const APRON_SKIRT := 1             # outer-skirt depth in s_max units (tuck under megablock walls)
const LOD_REQUESTS_PER_TICK := 2   # new facet builds admitted per tick — PACES probe-generator creation + enqueues
                                   # across frames (never a set-time/crossing-time flood of ~48 generators, §6.4)

# ---- state ----
var _mod: Object = null                    # module_world (probe generators + baked library + pool membership)
var _builder = null                        # the ONE FacetLodBuilder this mesher owns
var _active_fid := -1
var _cam: Camera3D = null                   # M2c selector input (stored, unused in M2b)
var _controller = null                      # M2c/d StreamLoadController (stored, unused in M2b)
var _apron_mat: StandardMaterial3D = null

var _cache: Dictionary = {}                 # fid -> {lod,node,tris,bytes,last_want_ms, apron:{slot->{mi,s_max,tris,bytes}}}
var _building: Dictionary = {}              # fid -> {lod,expected,got,staging:Node3D,tris,bytes,est_tris,est_bytes}
var _apron_building: Dictionary = {}        # "owner:slot" -> s_max (in-flight apron jobs, dedup)
var _want: Dictionary = {}                  # fid -> desired tier (the target rung; recomputed on active/pool change)
var _pending: Array = []                    # drained-but-not-yet-applied items (carried across apply budgets)
var _ledger_tris := 0                       # running sum: applied + in-flight (estimated) triangles
var _ledger_bytes := 0                      # running sum: applied + in-flight (estimated) bytes

# §1.3 per-tier planning estimates (tris, bytes) — admission bounds in-flight work BEFORE building; reconciled to
# the measured mesh at apply. Deliberately generous so the estimate is an upper fence on the real cost.
const _EST_TRIS := {1: 30000, 2: 7500, 3: 2000}
const _EST_BYTES := {1: 3_600_000, 2: 950_000, 3: 240_000}

# ============================ setup / teardown ============================

## Wire the builder + warm the off-thread readers. Returns false (safe no-op) when the flag is off or the module /
## mesher class is unavailable — module_world then leaves _lod_mesher null and the whole LOD path is dead.
func setup(module_world: Object) -> bool:
	if not CubeSphere.FP_M2_LOD:
		return false
	if module_world == null:
		return false
	_mod = module_world
	_builder = FLB.new()
	if not bool(_builder.setup(module_world)):
		_builder = null
		return false
	# Warm every reader the builder thread touches for the APRON path (generate_block's readers are already warm):
	# FarPalette resolves catalog tints once, TerrainConfig.profile_at_dir needs the noise singletons. Both are
	# frozen after this call → the apron job is a pure reader (§7.4 thread-safety class).
	FarPalette.ensure_ready()
	TerrainConfig.warm_up()
	_apron_mat = StandardMaterial3D.new()
	_apron_mat.vertex_color_use_as_albedo = true
	_apron_mat.cull_mode = BaseMaterial3D.CULL_DISABLED     # winding-agnostic (the dihedral turn can flip a strip)
	_apron_mat.roughness = 1.0
	return true

## M2c selector input (fov, viewport, camera position). Stored now; the SSE selector that consumes it is M2c.
func set_camera(cam: Camera3D) -> void:
	_cam = cam

## M2c/d admission controller. Stored now; the credit that scales apply-ms + grants is M2c.
func set_load_controller(c) -> void:
	_controller = c

## Join the builder thread and free every LOD node. MUST run before this node (or its PlanetRoot parent) is freed —
## a bare queue_free would leak the running builder Thread. module_world calls this on pool_reset + _exit_tree.
func shutdown() -> void:
	if _builder != null:
		_builder.shutdown()
		_builder = null
	for fid in _cache.keys():
		var n: Node3D = _cache[fid]["node"]
		if n != null and is_instance_valid(n):
			n.queue_free()
	for fid in _building.keys():
		var s: Node3D = _building[fid]["staging"]
		if s != null and is_instance_valid(s):
			s.free()                                        # never entered the tree → free() not queue_free()
	_cache.clear(); _building.clear(); _apron_building.clear(); _want.clear(); _pending.clear()
	_ledger_tris = 0; _ledger_bytes = 0

# ============================ tier policy (STATIC per-ring, M2b) ============================

## Recompute the static per-ring target tiers for `active`, drop stale facets. Called from module_world on init +
## every crossing (redesignate / pool_reset). The wanted facets are BUILT by tick()'s paced request pass — NOT
## enqueued here, so a crossing never floods ~48 probe-generator creations onto the crossing frame (§6.4 pacing).
func set_active_facet(active: int) -> void:
	_active_fid = active
	_recompute_wants()
	# Evict facets that are no longer wanted (a crossing shifted the covered rings). Cheap unloads, never throttled.
	for fid in _cache.keys():
		if not _want.has(fid):
			evict(fid)
	for fid in _building.keys():
		if not _want.has(fid):
			_cancel_build(fid)

## The live pool (spawn/retire/redesignate) changed — a facet may have gone live (exclude it) or freed (re-cover).
func notify_pool_changed() -> void:
	_recompute_wants()
	for fid in _cache.keys():
		if not _want.has(fid):
			evict(fid)

## STATIC ring rule (§13): every front-hemisphere facet within LOD_COVER_RINGS of the active facet gets a tier
## (ring-1 → ℓ1 … ring-3 → ℓ3); the active facet and any LIVE pool facet are excluded (live terrain covers them);
## beyond the covered rings stays quad. Ring = round(angle / facet-angular-step) — robust across face seams.
func _recompute_wants() -> void:
	_want.clear()
	if _active_fid < 0 or not FacetAtlas.is_ready():
		return
	var live := {}
	if _mod != null and _mod.has_method("pool_fids"):
		for f in _mod.call("pool_fids"):
			live[int(f)] = true
	var nrm: Array = FacetAtlas.facet_normal64(_active_fid)
	var ac := _centre_dir(_active_fid)
	var step := (PI * 0.5) / float(FacetAtlas.K)                # one grid step of angular facet size
	var nf := FacetAtlas.facet_count()
	for fid in range(nf):
		if fid == _active_fid or live.has(fid):
			continue
		var cd := _centre_dir(fid)
		if cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] < 0.0:
			continue                                            # back hemisphere — below the horizon, quad suffices
		var dot: float = clampf(cd[0] * ac[0] + cd[1] * ac[1] + cd[2] * ac[2], -1.0, 1.0)
		var ring := int(round(acos(dot) / step))
		if ring >= 1 and ring <= LOD_COVER_RINGS:
			_want[fid] = mini(ring, LOD_MAX_TIER)

func _centre_dir(fid: int) -> Array:
	var cc: Vector2i = FacetAtlas.centre_cell(fid)
	var d: CubeSphere.DVec3 = FacetAtlas.cell_dir(fid, cc.x, cc.y)
	return [d.x, d.y, d.z]

## Paced request pass (called from tick): admit at most LOD_REQUESTS_PER_TICK new wanted facets per frame, finest
## tier first, and only while the builder queue is shallow — so probe-generator creation + enqueues spread across
## frames instead of stalling one (setup / crossing) frame with ~48 of them. Admission (§6.2 caps) still bounds it.
func _pace_requests() -> void:
	if _builder == null or int(_builder.queued()) > LOD_QUEUE_MAX_JOBS:
		return
	# FP-M2c surface 2 (§6.5.3.2): the per-tick admit count is scaled by the controller credit — ceil(2·credit),
	# 0 → the budgeter stops enqueueing (the builder finishes in-flight tiles and idles). Default = LOD_REQUESTS_PER_TICK.
	var grants := LOD_REQUESTS_PER_TICK
	if _controller != null:
		grants = int(_controller.call("grant_count", LOD_REQUESTS_PER_TICK))
	if grants <= 0:
		return
	var order := _want.keys()
	order.sort_custom(func(a, b): return int(_want[a]) < int(_want[b]))
	var made := 0
	for fid in order:
		if made >= grants:
			break
		var lod := int(_want[fid])
		if _cache.has(fid) and int(_cache[fid]["lod"]) == lod:
			continue
		if _building.has(fid) and int(_building[fid]["lod"]) == lod:
			continue
		request(fid, lod)
		made += 1

# ============================ request / admission (NEVER-OOM) ============================

## Request facet `fid` at tier `lod`. Marks it wanted, then admits it against the hard caps (evicting NON-wanted
## LRU facets to fund, degrading the grant one tier when only wanted facets remain, denying to quad at the coarsest
## tier). Public so G-M2-CAPS can storm it directly. A no-op for the active facet or a live pool facet. `dry` =
## admit + track WITHOUT enqueuing a real build (the caps/LRU gate exercises admission synchronously; real builds
## are covered by G-M2-BUILD/FRAME/SEAM). Returns the granted tier, or −1 when denied to quad.
func request(fid: int, lod: int, dry: bool = false) -> int:
	if fid < 0 or fid == _active_fid:
		return -1
	if _mod != null and _mod.has_method("pool_has") and bool(_mod.call("pool_has", fid)):
		return -1
	lod = clampi(lod, 1, LOD_MAX_TIER)
	_want[fid] = lod
	if _cache.has(fid):
		_cache[fid]["last_want_ms"] = Time.get_ticks_msec()
		if int(_cache[fid]["lod"]) == lod:
			return lod                                        # already applied at this tier
	if _building.has(fid) and int(_building[fid]["lod"]) == lod:
		return lod                                            # already in flight at this tier
	var granted := _admit(fid, lod)
	if granted < 0:
		return -1                                             # denied → stays quad (never a hole)
	_start_build(fid, granted, dry)
	return granted

## Estimate-based admission. Returns the granted tier (≥ lod, coarser under pressure) or -1 (deny → quad).
func _admit(fid: int, lod: int) -> int:
	var cap_bytes := LOD_MAX_BYTES_MB * 1024 * 1024
	var cand := lod
	while cand <= LOD_MAX_TIER:
		# Subtract fid's own current contribution (a re-tier replaces, not adds).
		var cur_tris := _ledger_tris - _fid_tris(fid)
		var cur_bytes := _ledger_bytes - _fid_bytes(fid)
		var tracked := _tracked_count(fid)                    # count with fid included once
		# facet-count cap (tier-independent): evict a NON-wanted LRU facet if full, else deny.
		while tracked > LOD_MAX_FACETS:
			if not _evict_one_non_wanted(fid):
				return -1
			cur_tris = _ledger_tris - _fid_tris(fid)
			cur_bytes = _ledger_bytes - _fid_bytes(fid)
			tracked = _tracked_count(fid)
		var proj_tris := cur_tris + int(_EST_TRIS[cand])
		var proj_bytes := cur_bytes + int(_EST_BYTES[cand])
		if proj_tris <= LOD_MAX_TRIS and proj_bytes <= cap_bytes:
			return cand
		# Over a tri/byte cap: evict NON-wanted LRU to fund; if none left, degrade one tier coarser.
		if not _evict_one_non_wanted(fid):
			cand += 1
	return -1

func _start_build(fid: int, lod: int, dry: bool = false) -> void:
	_cancel_build(fid)                                        # supersede any in-flight build at a different tier
	if _builder == null and not dry:
		return
	var staging := Node3D.new()
	staging.name = "LodFacet_%d" % fid
	staging.transform = FacetAtlas.facet_transform(fid)
	var tiles: int = 1 if dry else int(_builder.enqueue_facet(fid, lod))
	if tiles <= 0:
		staging.free()
		return
	_building[fid] = {
		"lod": lod, "expected": tiles, "got": 0, "staging": staging, "dry": dry,
		"tris": 0, "bytes": 0, "est_tris": int(_EST_TRIS[lod]), "est_bytes": int(_EST_BYTES[lod]),
	}
	_ledger_tris += int(_EST_TRIS[lod])
	_ledger_bytes += int(_EST_BYTES[lod])

## Drop an in-flight build (superseded / evicted). Its still-queued tiles are dropped at the builder's dequeue; any
## already-drained tiles for it fall through the lod/tracking guard in tick(). Frees the staging node + est ledger.
func _cancel_build(fid: int) -> void:
	if not _building.has(fid):
		return
	var b: Dictionary = _building[fid]
	_ledger_tris -= int(b["est_tris"]); _ledger_bytes -= int(b["est_bytes"])
	var s: Node3D = b["staging"]
	if s != null and is_instance_valid(s):
		s.free()
	_building.erase(fid)

# ============================ per-frame tick (drain + apply + apron) ============================

## Per frame (module_world._process): drain the builder, apply finished meshes under LOD_APPLY_BUDGET_MS (atomic
## whole-facet swap — never a half-applied facet), then reconcile the apron coverage. Cheap when idle.
func tick() -> void:
	if _builder == null:
		return
	for item in _builder.drain_done():
		_pending.append(item)
	# FP-M2c surface 1 (§6.5.3.1): the apply budget is scaled by the controller credit — 0 → applies PAUSE (the
	# finished meshes wait in _pending, bounded because they are already built). Default (no controller) = the M2b
	# fixed LOD_APPLY_BUDGET_MS. Credit-scaled ms/frame governs how fast built meshes swap into the scene.
	var apply_ms := LOD_APPLY_BUDGET_MS
	if _controller != null:
		apply_ms = float(_controller.call("apply_budget_ms", LOD_APPLY_BUDGET_MS))
	if apply_ms > 0.0:
		var t0 := Time.get_ticks_usec()
		var budget_us := int(apply_ms * 1000.0)
		while not _pending.is_empty():
			_apply_one(_pending.pop_front())
			if Time.get_ticks_usec() - t0 > budget_us:
				break
	_pace_requests()                                          # admit a few new wanted facets (paced, §6.4)
	_apron_pass()

func _apply_one(item: Dictionary) -> void:
	if item.get("kind", "tile") == "apron":
		_apply_apron(item)
		return
	var fid: int = item["fid"]
	if not _building.has(fid) or int(_building[fid]["lod"]) != int(item["lod"]):
		return                                                # stale (superseded / evicted) — drop the mesh
	var b: Dictionary = _building[fid]
	var mesh: Mesh = item["mesh"]
	if mesh != null and int(item["tris"]) > 0:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var s := 1 << int(item["lod"])
		var tile: Vector3i = item["tile"]
		mi.transform = Transform3D(Basis.from_scale(Vector3.ONE * float(s)), Vector3(tile))
		(b["staging"] as Node3D).add_child(mi)
		b["tris"] = int(b["tris"]) + int(item["tris"])
		b["bytes"] = int(b["bytes"]) + int(item["bytes"])
	b["got"] = int(b["got"]) + 1
	if int(b["got"]) >= int(b["expected"]):
		_swap_in(fid)

## §4.4 atomic swap: the facet's finished LodFacet staging node (built hidden, off-tree) becomes visible in ONE
## frame and the old tier is freed — no partial-facet frame, no flicker. Reconciles the estimated ledger to actual.
func _swap_in(fid: int) -> void:
	var b: Dictionary = _building[fid]
	var new_node: Node3D = b["staging"]
	var actual_tris: int = int(b["tris"]); var actual_bytes: int = int(b["bytes"])
	# ledger: remove the in-flight estimate, remove any old applied tier, add the new actual.
	_ledger_tris -= int(b["est_tris"]); _ledger_bytes -= int(b["est_bytes"])
	if _cache.has(fid):
		var old: Dictionary = _cache[fid]
		_ledger_tris -= int(old["tris"]); _ledger_bytes -= int(old["bytes"])
		for slot in old["apron"].keys():                      # carry the aprons over rather than double-free
			var ap: Dictionary = old["apron"][slot]
			_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
			(ap["mi"] as MeshInstance3D).queue_free()
		var on: Node3D = old["node"]
		if on != null and is_instance_valid(on):
			if on.get_parent() != null:
				on.get_parent().remove_child(on)
			on.queue_free()
	add_child(new_node)                                       # rigid under PlanetRoot @ facet_transform(fid)
	_ledger_tris += actual_tris; _ledger_bytes += actual_bytes
	_cache[fid] = {
		"lod": int(b["lod"]), "node": new_node, "tris": actual_tris, "bytes": actual_bytes,
		"last_want_ms": Time.get_ticks_msec(), "apron": {},
	}
	_building.erase(fid)

# ============================ ridge apron reconciliation (§7.4) ============================

## Reconcile aprons to the current LOD coverage: one apron per LOD↔LOD seam, owned by the LOWER fid; free aprons
## whose neighbour is no longer covered; enqueue (bounded) aprons that are missing or whose s_max changed.
func _apron_pass() -> void:
	if _builder == null:
		return
	for owner in _cache.keys():
		var lodO := int(_cache[owner]["lod"])
		var aprons: Dictionary = _cache[owner]["apron"]
		for slot in range(4):
			var nb: int = FacetAtlas.seam_neighbour(owner, slot)
			var desired: bool = nb >= 0 and nb != owner and owner < nb and _cache.has(nb)
			var key := "%d:%d" % [owner, slot]
			if desired:
				var s_max: int = 1 << maxi(lodO, int(_cache[nb]["lod"]))
				var have_ok: bool = aprons.has(slot) and int(aprons[slot]["s_max"]) == s_max
				if not have_ok and not _apron_building.has(key):
					if _builder.enqueue_apron(owner, slot, s_max):
						_apron_building[key] = s_max
			else:
				if aprons.has(slot):
					_free_apron(owner, slot)
				_apron_building.erase(key)

func _apply_apron(item: Dictionary) -> void:
	var owner: int = item["fid"]
	var slot: int = item["slot"]
	var key := "%d:%d" % [owner, slot]
	_apron_building.erase(key)
	if not _cache.has(owner):
		return                                                # owner evicted mid-build — drop
	var mesh: Mesh = item["mesh"]
	if mesh == null or int(item["tris"]) <= 0:
		return
	var aprons: Dictionary = _cache[owner]["apron"]
	if aprons.has(slot):
		_free_apron(owner, slot)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _apron_mat
	(_cache[owner]["node"] as Node3D).add_child(mi)
	aprons[slot] = {"mi": mi, "s_max": int(item["s_max"]), "tris": int(item["tris"]), "bytes": int(item["bytes"])}
	_ledger_tris += int(item["tris"]); _ledger_bytes += int(item["bytes"])

func _free_apron(owner: int, slot: int) -> void:
	var aprons: Dictionary = _cache[owner]["apron"]
	if not aprons.has(slot):
		return
	var ap: Dictionary = aprons[slot]
	_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
	var mi: MeshInstance3D = ap["mi"]
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	aprons.erase(slot)

# ============================ eviction / LRU ============================

## Free facet `fid`'s LOD node + aprons and subtract its ledger. Used by LRU funding, crossing shifts, promote
## completion (M2d). An evicted facet drops out of covered_fids() → the far-ring quad covers it (never a hole).
func evict(fid: int) -> void:
	_cancel_build(fid)
	if not _cache.has(fid):
		return
	var c: Dictionary = _cache[fid]
	for slot in c["apron"].keys():
		var ap: Dictionary = c["apron"][slot]
		_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
	_ledger_tris -= int(c["tris"]); _ledger_bytes -= int(c["bytes"])
	var n: Node3D = c["node"]
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	_cache.erase(fid)

## Evict the least-recently-wanted NON-wanted tracked facet (never `keep`, never a currently-wanted facet).
## Returns false when every tracked facet is wanted (the caller then degrades the grant instead — §6.4).
func _evict_one_non_wanted(keep: int) -> bool:
	var victim := -1
	var oldest := 0x7fffffffffffffff
	for fid in _cache.keys():
		if fid == keep or _want.has(fid):
			continue
		var w := int(_cache[fid]["last_want_ms"])
		if w < oldest:
			oldest = w; victim = fid
	if victim < 0:
		# no evictable applied facet — also consider dropping a non-wanted in-flight build
		for fid in _building.keys():
			if fid != keep and not _want.has(fid):
				_cancel_build(fid)
				return true
		return false
	evict(victim)
	return true

# ---- ledger helpers ----
func _fid_tris(fid: int) -> int:
	if _cache.has(fid): return int(_cache[fid]["tris"])
	if _building.has(fid): return int(_building[fid]["est_tris"])
	return 0

func _fid_bytes(fid: int) -> int:
	if _cache.has(fid): return int(_cache[fid]["bytes"])
	if _building.has(fid): return int(_building[fid]["est_bytes"])
	return 0

func _tracked_count(include: int) -> int:
	var seen := {}
	for fid in _cache.keys(): seen[fid] = true
	for fid in _building.keys(): seen[fid] = true
	seen[include] = true
	return seen.size()

# ============================ introspection (far-ring merge + gates + M2c HUD) ============================

## The facets holding an APPLIED LOD mesh — merged with the live pool into the FacetFarRing exclusion set (§5.5).
## Building-but-not-yet-applied facets are DELIBERATELY excluded so the quad stays until the LOD mesh is really up.
func covered_fids() -> Array:
	return _cache.keys()

func is_covered(fid: int) -> bool:
	return _cache.has(fid)

func active_facet() -> int:
	return _active_fid

func want_of(fid: int) -> int:
	return int(_want.get(fid, -1))

## Gate + PerfHUD snapshot: applied facet count, running tri/byte ledgers, in-flight builds, apron count, caps.
func stats() -> Dictionary:
	var aprons := 0
	for fid in _cache.keys():
		aprons += int((_cache[fid]["apron"] as Dictionary).size())
	return {
		"facets": _cache.size(), "building": _building.size(), "aprons": aprons,
		"tris": _ledger_tris, "bytes": _ledger_bytes,
		"max_facets": LOD_MAX_FACETS, "max_tris": LOD_MAX_TRIS, "max_bytes": LOD_MAX_BYTES_MB * 1024 * 1024,
		"builder_queued": int(_builder.queued()) if _builder != null else 0,
		"builder_built": int(_builder.build_count()) if _builder != null else 0,
	}

## Gate helper: the FacetLodBuilder this mesher owns (G-M2-BUILD / SEAM drive it directly for apron/tile builds).
func builder():
	return _builder

## Gate helpers (G-M2-FRAME / SEAM introspection). tile instances = the LOD megablock MeshInstances (material
## override null); apron instances carry _apron_mat. lod_of returns the applied tier (−1 if not covered).
func facet_tile_instances(fid: int) -> Array:
	var out: Array = []
	if not _cache.has(fid):
		return out
	for c in (_cache[fid]["node"] as Node3D).get_children():
		if c is MeshInstance3D and c.mesh != null and c.material_override != _apron_mat:
			out.append(c)
	return out

func lod_of(fid: int) -> int:
	return int(_cache[fid]["lod"]) if _cache.has(fid) else -1

func apron_slots(fid: int) -> Array:
	return (_cache[fid]["apron"] as Dictionary).keys() if _cache.has(fid) else []

func apron_mesh(fid: int, slot: int) -> Mesh:
	if _cache.has(fid) and (_cache[fid]["apron"] as Dictionary).has(slot):
		return (_cache[fid]["apron"][slot]["mi"] as MeshInstance3D).mesh
	return null

func is_building(fid: int) -> bool:
	return _building.has(fid)
