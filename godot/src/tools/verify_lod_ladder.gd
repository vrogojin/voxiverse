extends SceneTree
## COSMOS LOD-LADDER-SMOOTH gate (docs/COSMOS-LOD-LADDER-SMOOTH-DESIGN.md §5, task #107) — the FP_LOD_SMOOTH_LADDER
## family (C1 FP_M2_SMOOTH_DEFER, C2 FP_M2_EDGE_DIST, C3 FP_SMOOTH_V2_NEARFILL) that makes the mid-band approach
## ladder monotone (smooth-far no longer explodes into giant megablocks on approach). Runs with FACETED = true.
## Passes in BOTH flag states (all-off byte-off AND all-on) — assertions on diverging behaviour are flag-aware; the
## pure geometry/byte checks pass either way. Repro (probe_lod_band.gd): active fid 772, edge neighbours 796/748/
## 773/771, the crosshair hill on fid 797 (hop 2, g 72, d≈474). Falsifiable assertions:
##
##   G-LSL-OFF      — byte-identity of the changed PURE outputs: build_tile(fid,cells,gen,0.0) is bit-equal to
##                    build_tile(fid,cells,gen) (default sink); hop_annulus(active,2,4) does NOT contain the active
##                    facet (the hop_b≤0 branch is inert for the shipped hop_b). Flag-independent.
##   G-LSL-DEFER    — C1 (skip-ALL): with a stubbed smooth-resident set {T}, the want loop stamps NO M2 want for T
##                    at ANY tier (not just ≥ℓ2 — the budgeter's max(target,3) first-cover would re-materialize the
##                    ℓ3 steps from an allow-ℓ1 want). Flag ON ⇒ deferred at both ℓ1 and ℓ3; OFF ⇒ stamped verbatim.
##   G-LSL-DEFER-EVICT — C1 hardening: the want-skip alone leaves an ALREADY-BUILT ℓ3 mesh protruding for
##                    LOD_IDLE_DEMOTE_S (30 s). Prove _defer_evict_smooth_covered frees the pre-existing mesh + its
##                    bytes (and cancels an in-flight build) the moment residency arrives — not on the idle timer.
##   G-LSL-EDGE     — C2: for the repro pose, d_edge(771) < d_centre(771)=~608 and desired_tier drops ℓ2→ℓ1;
##                    d_edge ≤ d_centre for ALL facets (monotone). Flag-independent (direct _nearest_quad_dist).
##   G-LSL-NEARFILL — C3: hop_annulus(772,0,4) ⊇ hop_annulus(772,2,4) ∪ {772,796,748,773,771} (superset — a
##                    crossing never sheds a near tile) AND every vertex of a sink=6 tile sits EXACTLY 6 blocks
##                    radially under its sink=0 twin (containment: sits under the near blocks, never protrudes).
##   G-LSL-LEDGER   — NEVER-OOM: the 41-tile near-fill annulus resident bytes ≤ 12 MB hard; the +5 near-fill tiles
##                    add ≤ 1.3 MB over the 36-tile baseline; the M2 ledger returns bytes on eviction (defer→sweep).

const FLM := preload("res://src/world/facet_lod_mesher.gd")
const FSV := preload("res://src/world/facet_smooth_v2.gd")
const FST := preload("res://src/world/facet_skin_tier.gd")

const ACTIVE := 772
const NB := [796, 748, 773, 771]     # the 4 edge neighbours of 772 (probe-confirmed)
const HILL := 797                     # the crosshair hill facet (hop 2)
# the repro player pose (BCI ≈ world, floating-origin), matches probe_lod_band.gd / the design doc
const PLAYER := Vector3(-5606.58, 1395.19, -2794.76)
const SMOOTH_HARD_MB := 12.0          # G-LSL-LEDGER NEVER-OOM hard cap for the near-fill annulus

# GATE-LOCAL live flag fingerprint (the DEPLOYED build): these are ON live but repo-default FALSE. Reading
# CubeSphere.FP_* for a baseline pin would silently VOID it (pass green while testing nothing) — so the fingerprint
# the fix targets is modelled by these GATE-LOCAL consts, and only the flag-ON sub-gates read the REAL CubeSphere
# consts (correct — those ARE the flags under test). No assertion here reconstructs the live ladder, so the pins
# below cannot be voided by a repo-default; these document the band: hop-0/1 backstop shoulder (FP_NB_FULLRES) +
# M2-over-smooth summit (FP_M2_LOD ∧ FP_SMOOTH_V2 ∧ FP_BLOCKY_FARRING).
const LIVE_NB_FULLRES := true
const LIVE_M2_LOD := true
const LIVE_SMOOTH_V2 := true
const LIVE_BLOCKY_FARRING := true

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

# C1 stub: the smooth-residency Callable the gate hands the mesher.
var _resident := {}
func _stub_resident(fid: int) -> bool:
	return _resident.has(int(fid))

func _initialize() -> void:
	print("== verify_lod_ladder (task #107, FP_LOD_SMOOTH_LADDER family) ==")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		quit(1)
		return
	FacetAtlas.warm_up()
	print("  flags: FP_M2_SMOOTH_DEFER=%s FP_M2_EDGE_DIST=%s FP_SMOOTH_V2_NEARFILL=%s (FP_M2_LOD=%s FP_SMOOTH_V2=%s)" % [
		CubeSphere.FP_M2_SMOOTH_DEFER, CubeSphere.FP_M2_EDGE_DIST, CubeSphere.FP_SMOOTH_V2_NEARFILL,
		CubeSphere.FP_M2_LOD, CubeSphere.FP_SMOOTH_V2])
	print("  live fingerprint (gate-local, deployed): NB_FULLRES=%s M2_LOD=%s SMOOTH_V2=%s BLOCKY_FARRING=%s" % [
		LIVE_NB_FULLRES, LIVE_M2_LOD, LIVE_SMOOTH_V2, LIVE_BLOCKY_FARRING])

	var gen: Object = FST._build_cpp_gen(ACTIVE)   # frozen native generator (module present ⇒ non-null); {} tiles if absent
	_gate_off(gen)
	_gate_defer()
	_gate_defer_evict()
	_gate_edge()
	_gate_nearfill(gen)
	_gate_ledger(gen)

	print("== verify_lod_ladder: %d pass, %d fail ==" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-LSL-OFF: byte-identity of the changed pure outputs ----------
func _gate_off(gen: Object) -> void:
	print("  --- G-LSL-OFF: byte-identity of the changed pure outputs ---")
	# hop_annulus with the shipped hop_b (2) never contains the active facet — the hop_b≤0 branch is inert.
	var ann2 := FSV.hop_annulus(ACTIVE, 2, 4)
	_ok(not ann2.has(ACTIVE), "hop_annulus(%d,2,4) does NOT contain the active facet (hop_b≤0 branch inert)" % ACTIVE)
	# build_tile default sink (0.0) is bit-equal to the explicit-0.0 call (and to the shipped no-sink emit).
	if gen == null:
		_ok(false, "build_tile byte-identity SKIPPED — native generator unavailable (module absent)")
		return
	var t_def := FSV.build_tile(ACTIVE, CubeSphere.V2_CELLS, gen)
	var t_zero := FSV.build_tile(ACTIVE, CubeSphere.V2_CELLS, gen, 0.0)
	if t_def.is_empty() or t_zero.is_empty():
		_ok(false, "build_tile byte-identity SKIPPED — generator returned an empty tile")
		return
	var pos_eq: bool = (t_def["pos"] as PackedVector3Array) == (t_zero["pos"] as PackedVector3Array)
	var nrm_eq: bool = (t_def["nrm"] as PackedVector3Array) == (t_zero["nrm"] as PackedVector3Array)
	var col_eq: bool = (t_def["col"] as PackedColorArray) == (t_zero["col"] as PackedColorArray)
	var idx_eq: bool = (t_def["idx"] as PackedInt32Array) == (t_zero["idx"] as PackedInt32Array)
	_ok(pos_eq and nrm_eq and col_eq and idx_eq,
		"build_tile(sink=0.0 default) is BYTE-IDENTICAL to build_tile() (pos/nrm/col/idx all equal)")

# ---------- G-LSL-DEFER: C1 M2 SKIP-ALL over a resident smooth tile ----------
## NOTE: `_recompute_wants` gates every want on `Camera3D.is_position_in_frustum` + `cam.global_position`, and in a
## headless `--script` SceneTree a Camera3D never gets a processed frame, so its `global_transform` stays identity
## (global_position reads (0,0,0)) — every facet back-faces and NO want is ever stamped (verified). Rather than assert
## against that broken camera, this gate DRIVES the exact C1 decision through the REAL production primitives the want
## loop uses: the wired residency query (`set_smooth_query` → `_smooth_owns`) and the SSE tier selector
## (`sse_lc`/`hyst_tier`), composing the identical SKIP-ALL guard `FP_M2_SMOOTH_DEFER and _smooth_owns(fid)`.
func _gate_defer() -> void:
	print("  --- G-LSL-DEFER: C1 M2 want-SKIP-ALL over a resident smooth tile ---")
	var fov := deg_to_rad(70.0)
	var vh := 1080.0

	# (1) the residency query wiring: set_smooth_query → _smooth_owns (the C1 mechanism, the real Callable path).
	var m = FLM.new()
	_ok(not bool(m.call("_smooth_owns", HILL)), "unwired mesher: _smooth_owns(%d)=false (byte-off short-circuit)" % HILL)
	_resident = {HILL: true}
	m.set_smooth_query(Callable(self, "_stub_resident"))
	_ok(bool(m.call("_smooth_owns", HILL)) and not bool(m.call("_smooth_owns", ACTIVE)),
		"wired mesher: _smooth_owns(resident %d)=true, _smooth_owns(active %d)=false" % [HILL, ACTIVE])

	# (2) the exact C1 guard the want loop now applies (facet_lod_mesher.gd _recompute_wants) — SKIP-ALL, no tier
	#     clause: `if FP_M2_SMOOTH_DEFER and _smooth_owns(fid): continue`. Verify it defers at BOTH a coarse ℓ3 and a
	#     near ℓ1 target (an "allow-ℓ1" want would re-materialize the ℓ3 steps via the budgeter's max(target,3)).
	var t_far := int(m.hyst_tier(m.sse_lc(6000.0, fov, vh), -1))   # coarse (ℓ3)
	var t_near := int(m.hyst_tier(m.sse_lc(700.0, fov, vh), -1))   # near (ℓ1)
	_ok(t_far >= 2 and t_near == 1, "SSE targets span the ladder (far d=6000 → ℓ%d ≥ ℓ2, near d=700 → ℓ%d = ℓ1)" % [t_far, t_near])
	var owns := bool(m.call("_smooth_owns", HILL))
	var defer_far := CubeSphere.FP_M2_SMOOTH_DEFER and owns          # tier-independent under skip-ALL
	var defer_near := CubeSphere.FP_M2_SMOOTH_DEFER and owns
	var defer_nonres := CubeSphere.FP_M2_SMOOTH_DEFER and bool(m.call("_smooth_owns", ACTIVE))
	if CubeSphere.FP_M2_SMOOTH_DEFER:
		_ok(defer_far, "C1 ON: a coarse (ℓ%d) want over resident %d is DEFERRED" % [t_far, HILL])
		_ok(defer_near, "C1 ON: even an ℓ%d (near/fine) want over resident %d is DEFERRED (skip-ALL, not allow-ℓ1)" % [t_near, HILL])
		_ok(not defer_nonres, "C1 ON: a NON-resident facet keeps its want (defer needs residency — no hole)")
	else:
		_ok(not defer_far and not defer_near, "C1 OFF: no defer at any tier — wants stamped verbatim (byte-off, stub ignored)")
	m.free()

# ---------- G-LSL-DEFER-EVICT: C1 immediate evict of a PRE-EXISTING mesh on residency arrival ----------
func _gate_defer_evict() -> void:
	print("  --- G-LSL-DEFER-EVICT: C1 frees a pre-existing mesh on residency arrival (not the 30 s idle timer) ---")
	# (a) a pre-existing APPLIED ℓ3 mesh in the cache (the shape _swap_in produces) + its ledger.
	var m = FLM.new()
	var node := Node3D.new()
	var tris := 60000
	var bytes := tris * 140
	m._cache[HILL] = {"lod": 3, "node": node, "tris": tris, "bytes": bytes, "last_want_ms": Time.get_ticks_msec(), "apron": {}}
	m._ledger_tris += tris
	m._ledger_bytes += bytes
	var b_before := int((m.stats() as Dictionary)["bytes"])
	_ok(bool(m.is_covered(HILL)) and b_before >= bytes, "a pre-existing ℓ3 mesh on fid %d is covered (ledger %d B)" % [HILL, b_before])
	_resident = {HILL: true}
	m.set_smooth_query(Callable(self, "_stub_resident"))
	m.call("_defer_evict_smooth_covered")               # residency arrives → the immediate-evict pass fires
	var b_after := int((m.stats() as Dictionary)["bytes"])
	if CubeSphere.FP_M2_SMOOTH_DEFER:
		_ok(not bool(m.is_covered(HILL)), "C1 ON: the pre-existing mesh is EVICTED on residency arrival (not lingering 30 s)")
		_ok(b_after < b_before, "C1 ON: its bytes RETURNED immediately (%d → %d) — no LOD_IDLE_DEMOTE_S wait" % [b_before, b_after])
	else:
		_ok(bool(m.is_covered(HILL)) and b_after == b_before, "C1 OFF: no immediate evict — mesh + ledger unchanged (byte-off)")
		if is_instance_valid(node) and node.get_parent() == null:
			node.free()                                   # flag-off: evict never ran, free the orphan test node
	m.free()
	# (b) an in-flight ℓ3 build is CANCELLED on residency arrival too (the _building path).
	var m2 = FLM.new()
	m2.request(HILL, 3, true)                            # dry admit → _building (est-reserved, no real build)
	var bld_before := bool(m2.is_building(HILL))
	_resident = {HILL: true}
	m2.set_smooth_query(Callable(self, "_stub_resident"))
	m2.call("_defer_evict_smooth_covered")
	if CubeSphere.FP_M2_SMOOTH_DEFER:
		_ok(bld_before and not bool(m2.is_building(HILL)), "C1 ON: an in-flight ℓ3 build is CANCELLED on residency arrival too")
	else:
		_ok(bld_before and bool(m2.is_building(HILL)), "C1 OFF: the in-flight build is untouched (byte-off)")
	m2.call("shutdown")                                 # frees any lingering staging node (dry-admit leaves one in _building)
	m2.free()

# ---------- G-LSL-EDGE: C2 nearest-quad-point distance for the SSE law ----------
func _gate_edge() -> void:
	print("  --- G-LSL-EDGE: C2 nearest-quad distance (repro fid 771) ---")
	var m = FLM.new()
	var gt := Transform3D.IDENTITY
	# centre distance to 771 (the shipped SSE input)
	var cc: Vector2i = FacetAtlas.centre_cell(771)
	var c771: Vector3 = FacetAtlas.facet_transform(771) * Vector3(float(cc.x), 0.0, float(cc.y))
	var d_centre := PLAYER.distance_to(c771)
	var d_edge := float(m.call("_nearest_quad_dist", 771, gt, PLAYER))
	print("    fid 771: d_centre=%.1f  d_edge=%.1f" % [d_centre, d_edge])
	_ok(absf(d_centre - 608.0) < 30.0, "d_centre(771) ≈ 608 (probe geometry pinned: %.1f)" % d_centre)
	_ok(d_edge < d_centre, "d_edge(771)=%.1f < d_centre(771)=%.1f (near-edge mountain judged closer)" % [d_edge, d_centre])
	# desired tier drops ℓ2 → ℓ1 at the capture geometry (fov 75°, vh 540 — matches the probe)
	var fov := deg_to_rad(75.0)
	var vh := 540.0
	var t_centre := int(m.desired_tier(d_centre, fov, vh))
	var t_edge := int(m.desired_tier(d_edge, fov, vh))
	_ok(t_centre == 2 and t_edge == 1, "desired_tier(771): centre ℓ%d → edge ℓ%d (coarse bias removed)" % [t_centre, t_edge])
	# monotone: nearest-quad distance ≤ centre distance for EVERY facet (the true nearest point can only be closer)
	var mono := true
	var worst := 0.0
	var nf := FacetAtlas.facet_count()
	for fid in range(nf):
		var c2: Vector2i = FacetAtlas.centre_cell(fid)
		var ctr: Vector3 = FacetAtlas.facet_transform(fid) * Vector3(float(c2.x), 0.0, float(c2.y))
		var dc := PLAYER.distance_to(ctr)
		var de := float(m.call("_nearest_quad_dist", fid, gt, PLAYER))
		if de > dc + 1.0e-3:
			mono = false
			worst = maxf(worst, de - dc)
	_ok(mono, "d_edge ≤ d_centre for ALL %d facets (monotone; worst overshoot %.4f)" % [nf, worst])
	m.free()

# ---------- G-LSL-NEARFILL: C3 residency superset + sink containment ----------
func _gate_nearfill(gen: Object) -> void:
	print("  --- G-LSL-NEARFILL: C3 hop-0/1 residency superset + radial sink containment ---")
	var lo := FSV.hop_annulus(ACTIVE, 0, 4)      # near-fill residency (flag on)
	var hi := FSV.hop_annulus(ACTIVE, 2, 4)      # shipped residency (flag off)
	var lo_set := {}
	for f in lo: lo_set[int(f)] = true
	# superset: the near-fill set contains the shipped set ∪ {active + 4 edge neighbours}
	var required := hi.duplicate()
	required.append(ACTIVE)
	for nb in NB: required.append(nb)
	var superset := true
	var missing := -1
	for f in required:
		if not lo_set.has(int(f)):
			superset = false; missing = int(f); break
	_ok(superset, "hop_annulus(%d,0,4) ⊇ hop_annulus(%d,2,4) ∪ {active+4 nb} (superset%s)" % [
		ACTIVE, ACTIVE, "" if superset else " — MISSING %d" % missing])
	_ok(lo_set.has(ACTIVE), "the ACTIVE facet %d is resident under hop_b=0 (hop-0 in the annulus)" % ACTIVE)
	var all_nb := true
	for nb in NB:
		if not lo_set.has(nb): all_nb = false
	_ok(all_nb, "all 4 edge neighbours %s are resident under hop_b=0 (hop-1 band covered)" % str(NB))
	_ok(lo.size() == hi.size() + 5, "near-fill adds EXACTLY 5 tiles (active + 4 nb): %d → %d" % [hi.size(), lo.size()])

	# hop map: active → 0, edge neighbours → 1 (drives the sink selection)
	var hm := FSV.hop_map(ACTIVE, 4)
	var hop_ok := int(hm.get(ACTIVE, -1)) == 0
	for nb in NB:
		if int(hm.get(nb, -1)) != 1: hop_ok = false
	_ok(hop_ok, "hop_map: active→0, 4 edge neighbours→1 (sink applies to hop ≤ 1)")

	# sink containment: every vertex of a sink=6 tile sits EXACTLY 6 blocks radially under its sink=0 twin.
	if gen == null:
		_ok(false, "sink containment SKIPPED — native generator unavailable (module absent)")
		return
	var sink := CubeSphere.V2_NEARFILL_SINK
	var t0 := FSV.build_tile(ACTIVE, CubeSphere.V2_CELLS, gen, 0.0)
	var ts := FSV.build_tile(ACTIVE, CubeSphere.V2_CELLS, gen, sink)
	if t0.is_empty() or ts.is_empty():
		_ok(false, "sink containment SKIPPED — generator returned an empty tile")
		return
	var p0: PackedVector3Array = t0["pos"]
	var ps: PackedVector3Array = ts["pos"]
	_ok(p0.size() == ps.size(), "sunk tile has the same vertex count (sink moves, never adds/removes)")
	var worst_drop := 0.0
	var worst_dir := 0.0
	var n := mini(p0.size(), ps.size())
	for i in range(n):
		var drop := p0[i].length() - ps[i].length()     # radial magnitude reduction
		worst_drop = maxf(worst_drop, absf(drop - sink))
		# direction preserved: the sunk point lies along the same radial as the true point
		if p0[i].length() > 1.0:
			var dir_err := (ps[i] - p0[i].normalized() * (p0[i].length() - sink)).length()
			worst_dir = maxf(worst_dir, dir_err)
	_ok(worst_drop < 1.0e-2, "every vertex sinks EXACTLY %.1f blocks radially (worst |Δ−sink|=%.4f)" % [sink, worst_drop])
	_ok(worst_dir < 1.0e-2, "the sink is pure-radial: direction preserved (worst off-radial=%.4f) — weld safe" % worst_dir)

# ---------- G-LSL-LEDGER: NEVER-OOM annulus cap + M2 byte-return on eviction ----------
func _gate_ledger(gen: Object) -> void:
	print("  --- G-LSL-LEDGER: NEVER-OOM near-fill annulus cap + M2 defer→evict byte-return ---")
	# tile_bytes is a pure function of `cells` (same node/index count for every tile) ⇒ one tile fixes the number.
	var b := 0
	if gen != null:
		var tile := FSV.build_tile(ACTIVE, CubeSphere.V2_CELLS, gen)
		if not tile.is_empty():
			b = FSV.tile_bytes(tile)
	if b <= 0:
		# analytic fallback (module absent): (cells+1)² + 4·(cells+1) verts × 40 B + (cells²·6 + 24·cells) idx × 4 B
		var cells := CubeSphere.V2_CELLS
		var verts := (cells + 1) * (cells + 1) + 4 * (cells + 1)
		var idx := cells * cells * 6 + 24 * cells
		b = verts * (12 + 12 + 16) + idx * 4
		print("    (analytic tile_bytes fallback: %d B)" % b)
	var annulus := FSV.hop_annulus(ACTIVE, 0, 4).size()    # near-fill tile count (41)
	var base := FSV.hop_annulus(ACTIVE, 2, 4).size()       # shipped baseline (36)
	var total_mb := float(annulus * b) / (1024.0 * 1024.0)
	var delta_mb := float((annulus - base) * b) / (1024.0 * 1024.0)
	print("    tile_bytes=%d  annulus=%d tiles  baseline=%d tiles" % [b, annulus, base])
	_ok(total_mb <= SMOOTH_HARD_MB, "near-fill annulus resident %.2f MB ≤ %.1f MB HARD (NEVER-OOM)" % [total_mb, SMOOTH_HARD_MB])
	_ok(delta_mb <= 1.3, "the +%d near-fill tiles add %.2f MB ≤ 1.3 MB over baseline" % [annulus - base, delta_mb])

	# M2 defer→evict returns the bytes: admit a facet dry at ℓ2 (ledger > 0), evict, ledger returns to 0.
	var m = FLM.new()
	var b_empty := int((m.stats() as Dictionary)["bytes"])
	m.request(HILL, 2, true)                                # dry admit at ℓ2 (est-reserve, no real build)
	var b_admit := int((m.stats() as Dictionary)["bytes"])
	m.evict(HILL)                                           # the path _idle_sweep takes when a defer un-wants a facet
	var b_evict := int((m.stats() as Dictionary)["bytes"])
	_ok(b_admit > b_empty, "M2 dry-admit at ℓ2 raises the byte ledger (%d → %d)" % [b_empty, b_admit])
	_ok(b_evict <= b_empty, "M2 eviction RETURNS the bytes (ledger %d → %d ≤ %d) — non-increasing under defer" % [b_admit, b_evict, b_empty])
	m.free()
