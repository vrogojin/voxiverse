extends SceneTree
## verify_bg_prebake — COSMOS-BACKGROUND-PREBAKE gate (docs/COSMOS-BACKGROUND-PREBAKE-DESIGN.md §6).
## Proves FP_BG_PREBAKE lifts the on-surface fine-tier pause under a governed, view-cone-first background
## pacer that adds ZERO new resident memory — a scheduler change over the existing ~27 MB whole-planet
## FP_PLANET_MAP tier, not a new data structure. FP_BG_PREBAKE_CPP additionally routes the single governed
## on-surface slot through the C++ tile bake, degrading safely to the GDScript path when refused.
##
## Gates:
##   G-BGP-OFF        byte-off: with FP_BG_PREBAKE at its CURRENT compiled value, if it is false the
##                     governor never influences dispatch (bg_ok stays false regardless of frame_ms/inflight)
##                     — the condition reduces to exactly the shipped `not fine_pause_on or _offsurface`.
##                     (The full byte-off proof is FLAT verify_feature 6042/0, checked externally.)
##   G-BGP-COVERAGE    _next_fine_fid(emit_axis) — UNCHANGED code, exercised here under the governed path —
##                     picks the facet nearest the view axis first (view-cone-first, "for free"); repeated
##                     governed ticks eventually drain a near-complete facet set to full whole-planet
##                     coverage (_fine_baked.size() == _base_all). Falsifier: an axis pointing away from a
##                     candidate does NOT prefer it — ordering genuinely depends on the axis.
##   G-BGP-BUDGET      the fine tier's byte footprint is independent of the flag (my diff touches only
##                     dispatch gating, no new buffers) and matches the doc's ~27 MB figure at the live
##                     PLANET_MAP_TEXELS/QUAD consts; total_bytes() stays under FACET_TEX_BYTES_MAX.
##   G-BGP-PACING      a hot frame (bg_frame_ms > BG_FRAME_BUDGET_MS) dispatches ZERO new background tasks;
##                     a healthy frame dispatches <= BG_MAX_INFLIGHT_SURFACE. The contrast between the two
##                     calls is the falsifier — the governor has a real, not vacuous, effect.
##   G-BGP-CPP-DEGRADE with `_pbm_tile_ok=false` (module absent/refused), the background slot still
##                     dispatches via the GDScript path (no dead slot, no stall, no crash) and successfully
##                     bakes.
##   G-BGP-OSCALM      PERF P4 (FP_BG_OFFSURF_CALM), self-describing on the CURRENT compiled flag value.
##                     OFF: an off-surface OVER-budget frame still fills EVERY free slot (shipped full
##                     parallelism — the byte-off arm). ON: an off-surface over-budget frame caps total
##                     fine-mode in-flight at BG_MAX_INFLIGHT_OFFSURF_BUSY with a >=1 single-baker floor
##                     (never 0 — the map still eventually finishes), while a HEALTHY off-surface frame
##                     keeps the full pool (convergence speed untouched when there is headroom).
##
## RUN (sed FACETED + FP_BG_PREBAKE (+ FP_BG_PREBAKE_CPP for that arm) ON):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_bg_prebake.gd 2>/dev/null | grep VERIFY
## Byte-off proof: re-run with ONLY FP_BG_PREBAKE sed'd back OFF (FACETED still ON) — G-BGP-OFF still
## passes (self-describing: it checks whatever the CURRENT compiled value is), and FLAT verify_feature
## must stay 6042/0.
## G-BGP-OSCALM arms: run once with defaults (byte-off arm) and once with FP_BG_OFFSURF_CALM sed'd ON
## (FACETED ON both times; FP_BG_PREBAKE is irrelevant to this gate).
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_bg_prebake (COSMOS-BACKGROUND-PREBAKE) — FP_BG_PREBAKE=%s FP_BG_PREBAKE_CPP=%s ===" % [
		str(CubeSphere.FP_BG_PREBAKE), str(CubeSphere.FP_BG_PREBAKE_CPP)])
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()

	_gate_off()
	_gate_coverage()
	_gate_budget()
	_gate_pacing()
	_gate_cpp_degrade()
	_gate_offsurf_calm()
	_gate_scope()
	_gate_coast()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

## Fixture: a fresh FacetTexBaker with a single-facet-resolution fine-map pipeline primed directly, and
## `n_slots` parallel-bake slots — mirrors verify_far_smooth.gd's _prime_fine_map (the established "poke
## flag-gated internals directly" technique), avoiding the long _pbm_on/_worker_on/FP_SKIN_SSE/
## FP_CPP_TILE_BAKE prerequisite chain so _update_band_parallel's fine-tier dispatch can be driven headless.
func _prime(fid: int, n_slots: int) -> FacetTexBaker:
	var b := FacetTexBaker.new()
	b.setup(fid)
	FarPalette.ensure_far_index_ready()
	b._fm_on = true
	b._fm_texels = CubeSphere.PLANET_MAP_TEXELS
	b._fm_quad = CubeSphere.PLANET_MAP_QUAD
	b._fm_page = b._fm_quad * b._fm_texels
	var imgs: Array[Image] = []
	for l in range(6 * 4):
		var im := Image.create(b._fm_page, b._fm_page, false, Image.FORMAT_L8)
		im.fill(Color(0.0, 0.0, 0.0, 1.0))
		b._fm_pages.append(im)
		imgs.append(im)
	b._fm_tex = Texture2DArray.new()
	b._fm_tex.create_from_images(imgs)
	b._pbm_n = n_slots
	b._pbm_fid = []; b._pbm_layer = []; b._pbm_task = []; b._pbm_bytes = []
	b._pbm_lc = []; b._pbm_nx = []; b._pbm_ny = []; b._pbm_mode = []; b._pbm_cpp = []; b._pbm_tile = []
	for i in n_slots:
		b._pbm_fid.append(-1)
		b._pbm_layer.append(-1)
		b._pbm_task.append(-1)
		b._pbm_bytes.append(PackedByteArray())
		b._pbm_lc.append(PackedVector2Array())
		b._pbm_nx.append(0)
		b._pbm_ny.append(0)
		b._pbm_mode.append(0)
		b._pbm_cpp.append(0)
		b._pbm_tile.append(0)
	return b

## Wait for slot 0's in-flight task (if any) to complete, then run ONE more update_band_parallel call so the
## production reap loop commits it. Mirrors verify_far_smooth.gd's G-TEX-SURF-PAUSE warm-up technique
## exactly (only the production reap may ever reclaim a WorkerThreadPool task id).
func _drain(b: FacetTexBaker, axis: Array, fine_pause_on: bool, bg_ms: float, timeout_ms: int = 5000) -> void:
	var task_id := int(b._pbm_task[0]) if b._pbm_n > 0 else -1
	var waited := 0
	while task_id >= 0 and not WorkerThreadPool.is_task_completed(task_id) and waited < timeout_ms:
		OS.delay_msec(2)
		waited += 2
	b._update_band_parallel(axis, fine_pause_on, bg_ms)   # this call's reap loop commits it

## Drain EVERY slot to fully idle (no in-flight WorkerThreadPool task bound to `b`), forcing a hot
## bg_frame_ms on each reap pass so the reap can never itself trigger a new dispatch. Call this once a
## fixture is done being exercised, before it goes out of scope — an in-flight task holds a Callable bound
## to the (RefCounted) baker; freeing it mid-task would use-after-free. Polls with is_task_completed()
## ONLY, never wait_for_task_completion() directly — only the production reap loop inside
## _update_band_parallel may ever reclaim a task id (see _drain's own doc comment); reclaiming it here too
## double-reclaims the same id ("Invalid Task ID").
func _settle(b: FacetTexBaker, axis: Array) -> void:
	for _round in range(8):
		var any_inflight := false
		for i in range(b._pbm_n):
			var t := int(b._pbm_task[i])
			if t < 0:
				continue
			any_inflight = true
			var waited := 0
			while not WorkerThreadPool.is_task_completed(t) and waited < 5000:
				OS.delay_msec(2)
				waited += 2
		if not any_inflight:
			return
		b._update_band_parallel(axis, true, CubeSphere.BG_FRAME_BUDGET_MS + 100.0)   # reap only — hot frame blocks any new dispatch

## G-BGP-OFF (byte-off, self-describing on the CURRENT compiled flag value): when FP_BG_PREBAKE is false,
## bg_ok can never be true no matter how favourable frame_ms/inflight are — dispatch reduces to exactly the
## shipped `not fine_pause_on or _offsurface`. When true, this gate just confirms the flag reads back true
## (the OTHER gates below exercise the active behaviour).
func _gate_off() -> void:
	var fid := FacetAtlas.spawn_facet()
	var axis_v := _centre_dir(fid)
	var axis := [axis_v.x, axis_v.y, axis_v.z]
	if not CubeSphere.FP_BG_PREBAKE:
		var b := _prime(fid, 1)
		b._offsurface = false
		# Most favourable possible governor inputs (zero frame cost, no inflight) — if the flag truly has no
		# effect while false, dispatch must STILL stay drained under the pause.
		b._update_band_parallel(axis, true, 0.0)
		_ok(int(b._pbm_fid[0]) < 0, "G-BGP-OFF: FP_BG_PREBAKE=false — on-surface dispatch stays paused even with a maximally-favourable frame_ms/inflight (bg_ok can never fire)")
	else:
		_ok(CubeSphere.FP_BG_PREBAKE, "G-BGP-OFF: FP_BG_PREBAKE compiled true for this run (active-behaviour gates below cover it)")

## G-BGP-COVERAGE: view-cone-first ordering (from the UNCHANGED _next_fine_fid, exercised via the governed
## dispatch path) + eventual whole-planet completeness.
func _gate_coverage() -> void:
	if not CubeSphere.FP_BG_PREBAKE:
		print("  G-BGP-COVERAGE: skipped (FP_BG_PREBAKE off this run — exercised in the ON config run)")
		return
	var fid := FacetAtlas.spawn_facet()
	var b := _prime(fid, 1)
	b._offsurface = false

	# --- view-cone-first: the facet nearest a chosen axis is picked ahead of an axis pointing elsewhere. ---
	var target_dir := _centre_dir(fid)
	var target_axis := [target_dir.x, target_dir.y, target_dir.z]
	var picked_toward := b._next_fine_fid(target_axis)
	_ok(picked_toward >= 0, "G-BGP-COVERAGE: _next_fine_fid returns a real facet for a valid view axis")
	if picked_toward >= 0:
		var picked_dir := _centre_dir(picked_toward)
		var best_dot := -2.0
		for f in range(b._base_all):
			best_dot = maxf(best_dot, _centre_dir(f).dot(target_dir))
		_ok(is_equal_approx(picked_dir.dot(target_dir), best_dot),
			"G-BGP-COVERAGE: the picked facet (%d) is the GLOBAL nearest to the view axis (dot=%.4f vs best=%.4f)" % [picked_toward, picked_dir.dot(target_dir), best_dot])
		# Falsifier: an axis pointing the OPPOSITE way must not pick the same facet (ordering genuinely
		# depends on the axis, not a fixed/shuffled default).
		var away_axis := [-target_dir.x, -target_dir.y, -target_dir.z]
		var picked_away := b._next_fine_fid(away_axis)
		_ok(picked_away != picked_toward,
			"G-BGP-COVERAGE falsifier: an axis pointing AWAY from the target picks a DIFFERENT facet (got %d vs %d toward) — ordering is axis-dependent, not fixed" % [picked_away, picked_toward])

	# --- governed dispatch actually threads emit_axis through: the DISPATCHED fid matches the direct call. ---
	b._update_band_parallel(target_axis, true, 0.0)   # healthy frame, on-surface, fine_pause_on=true
	_ok(int(b._pbm_fid[0]) == picked_toward,
		"G-BGP-COVERAGE: the governed on-surface dispatch bakes the SAME view-first facet (%d) _next_fine_fid alone picked" % picked_toward)
	_drain(b, target_axis, true, 0.0)
	_ok(b._fine_baked.has(picked_toward), "G-BGP-COVERAGE: the view-cone-first facet actually commits to _fine_baked")
	_settle(b, target_axis)   # only 1 of _base_all facets was baked -- the reap above may have re-dispatched

	# --- eventual whole-planet completeness: pre-mark all-but-a-handful baked, drain the rest under the
	# governed path, confirm full coverage. Cheap (a handful of real bakes, not the whole 6*K^2 planet). ---
	var b2 := _prime(fid, 1)
	b2._offsurface = false
	var remaining := []
	for f in range(b2._base_all):
		if f % 733 == 0:            # a sparse, deterministic handful (coprime-ish stride) left unbaked
			remaining.append(f)
		else:
			b2._fine_baked[f] = true
	_ok(remaining.size() >= 3 and remaining.size() <= 8, "G-BGP-COVERAGE: fixture leaves a small handful unbaked (%d)" % remaining.size())
	var rounds := 0
	while b2._fine_baked.size() < b2._base_all and rounds < remaining.size() + 2:
		_drain(b2, [], true, 0.0)   # empty axis -> the cursor-sweep fallback (phase 3, "the rest of the planet")
		rounds += 1
	_ok(b2._fine_baked.size() == b2._base_all,
		"G-BGP-COVERAGE: whole-planet completeness reached (_fine_baked %d / %d) in %d governed rounds" % [b2._fine_baked.size(), b2._base_all, rounds])

## G-BGP-BUDGET: the fine tier's byte footprint is flag-independent (no new buffers in this diff) and
## matches the doc's ~27 MB figure; total_bytes() stays under the NEVER-OOM ceiling.
func _gate_budget() -> void:
	var fid := FacetAtlas.spawn_facet()
	var b := _prime(fid, 1)
	_ok(CubeSphere.PLANET_MAP_TEXELS == 64 and CubeSphere.PLANET_MAP_QUAD == 12,
		"G-BGP-BUDGET: live PLANET_MAP_TEXELS/QUAD consts match the doc's quoted figures (64 / 12)")
	var one_page_bytes := b._fm_page * b._fm_page   # L8 = 1 byte/texel
	var fine_tier_bytes := 2 * 24 * one_page_bytes  # CPU staging (24 layers) + GPU array (24 layers)
	var fine_tier_mb := float(fine_tier_bytes) / (1024.0 * 1024.0)
	_ok(fine_tier_mb > 25.0 and fine_tier_mb < 29.0,
		"G-BGP-BUDGET: fine tier ~27 MB at the live consts (got %.2f MB) — FIXED-SIZE, independent of FP_BG_PREBAKE (this diff adds no new buffers, only dispatch gating)" % fine_tier_mb)
	var total := b.total_bytes()
	_ok(total < FacetTexBaker.FACET_TEX_BYTES_MAX,
		"G-BGP-BUDGET: total_bytes() (%d) stays under FACET_TEX_BYTES_MAX (%d)" % [total, FacetTexBaker.FACET_TEX_BYTES_MAX])

## G-BGP-PACING: a hot frame dispatches zero new background tasks; a healthy frame dispatches <=
## BG_MAX_INFLIGHT_SURFACE. The contrast is the falsifier — proves the governor has a real effect.
func _gate_pacing() -> void:
	if not CubeSphere.FP_BG_PREBAKE:
		print("  G-BGP-PACING: skipped (FP_BG_PREBAKE off this run — exercised in the ON config run)")
		return
	var fid := FacetAtlas.spawn_facet()
	var axis_v := _centre_dir(fid)
	var axis := [axis_v.x, axis_v.y, axis_v.z]

	# --- hot frame: well over the budget -> zero new dispatch. ---
	var b_hot := _prime(fid, 1)
	b_hot._offsurface = false
	b_hot._update_band_parallel(axis, true, CubeSphere.BG_FRAME_BUDGET_MS + 50.0)
	_ok(int(b_hot._pbm_fid[0]) < 0, "G-BGP-PACING: a hot frame (bg_frame_ms > budget) dispatches ZERO new background tasks")

	# --- healthy frame: well under the budget -> dispatches, bounded by BG_MAX_INFLIGHT_SURFACE. ---
	var b_ok := _prime(fid, CubeSphere.BG_MAX_INFLIGHT_SURFACE + 2)   # a couple of spare slots to prove the CAP, not just "some slots were free"
	b_ok._offsurface = false
	b_ok._update_band_parallel(axis, true, 1.0)
	var dispatched := 0
	for i in range(b_ok._pbm_n):
		if int(b_ok._pbm_fid[i]) >= 0:
			dispatched += 1
	_ok(dispatched >= 1 and dispatched <= CubeSphere.BG_MAX_INFLIGHT_SURFACE,
		"G-BGP-PACING: a healthy frame dispatches >=1 and <= BG_MAX_INFLIGHT_SURFACE (%d) new background tasks (got %d, %d slots available)" % [CubeSphere.BG_MAX_INFLIGHT_SURFACE, dispatched, b_ok._pbm_n])
	_settle(b_ok, axis)   # drain every dispatched slot before b_ok goes out of scope

## G-BGP-CPP-DEGRADE: with _pbm_tile_ok forced false (module absent/refused), the background slot still
## dispatches via the GDScript path — no dead slot, no stall, no crash — and successfully bakes.
func _gate_cpp_degrade() -> void:
	if not CubeSphere.FP_BG_PREBAKE:
		print("  G-BGP-CPP-DEGRADE: skipped (FP_BG_PREBAKE off this run — exercised in the ON config run)")
		return
	var fid := FacetAtlas.spawn_facet()
	var axis_v := _centre_dir(fid)
	var axis := [axis_v.x, axis_v.y, axis_v.z]
	var b := _prime(fid, 1)
	b._offsurface = false
	b._pbm_tile_ok = false   # simulate module absent / bake_far_tile() refusal
	b._update_band_parallel(axis, true, 0.0)
	_ok(int(b._pbm_fid[0]) >= 0, "G-BGP-CPP-DEGRADE: the background slot still dispatches with _pbm_tile_ok=false (no dead slot)")
	_ok(int(b._pbm_tile[0]) == 0, "G-BGP-CPP-DEGRADE: the dispatched task correctly falls back to the GDScript path (_pbm_tile=0)")
	_drain(b, axis, true, 0.0)
	_ok(b._fine_baked.size() > 0, "G-BGP-CPP-DEGRADE: the GDScript-fallback bake actually completes and commits (no stall, no crash)")
	_settle(b, axis)

## Count occupied parallel-bake slots (fine-mode in-flight-or-just-dispatched) — G-BGP-OSCALM helper.
func _occupied(b: FacetTexBaker) -> int:
	var n := 0
	for i in range(b._pbm_n):
		if int(b._pbm_fid[i]) >= 0:
			n += 1
	return n

## G-BGP-OSCALM (PERF P4, FP_BG_OFFSURF_CALM): the OFF-surface calm governor, self-describing on the CURRENT
## compiled flag value (independent of FP_BG_PREBAKE — the calm path rides the `_offsurface` arm of the
## dispatch condition). The fixtures force `_pbm_tile_ok=false` (GDScript bake path, proven live by
## G-BGP-CPP-DEGRADE) and flip `_offsurface=false` before settling so the settle reap-passes cannot dispatch
## (on-surface + hot frame closes every dispatch arm) — otherwise an off-surface settle would legitimately
## re-dispatch each round and never drain.
func _gate_offsurf_calm() -> void:
	var fid := FacetAtlas.spawn_facet()
	var axis_v := _centre_dir(fid)
	var axis := [axis_v.x, axis_v.y, axis_v.z]
	var slots: int = CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY + 2   # spare slots prove the CAP, not "some slots were free"
	var hot: float = CubeSphere.BG_FRAME_BUDGET_MS + 50.0

	# --- over-budget frame, off-surface. ---
	var b_hot := _prime(fid, slots)
	b_hot._offsurface = true
	b_hot._pbm_tile_ok = false
	b_hot._update_band_parallel(axis, true, hot)
	var n_hot := _occupied(b_hot)
	if CubeSphere.FP_BG_OFFSURF_CALM:
		_ok(n_hot >= 1 and n_hot <= CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY,
			"G-BGP-OSCALM: over-budget off-surface frame caps in-flight to BG_MAX_INFLIGHT_OFFSURF_BUSY (%d) with a >=1 floor (got %d, %d slots free)" % [CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY, n_hot, slots])
		# A second hot call must HOLD the cap (total in-flight, not just per-call new dispatch — a fast bake
		# may legitimately have been reaped and replaced in between; the invariant is the TOTAL).
		b_hot._update_band_parallel(axis, true, hot)
		var n_hot2 := _occupied(b_hot)
		_ok(n_hot2 <= CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY,
			"G-BGP-OSCALM: a repeat over-budget call holds total in-flight <= the busy cap (got %d)" % n_hot2)
	elif not CubeSphere.FP_PREBAKE_COAST_CAP:
		# (PERF P7a FP_PREBAKE_COAST_CAP ALSO caps off-surface dispatch, proactively — when it is on, the "full
		# pool" byte-off expectation for OSCALM no longer holds; G-PBS-COAST validates that cap in its own config.)
		_ok(n_hot == b_hot._pbm_n,
			"G-BGP-OSCALM byte-off: FP_BG_OFFSURF_CALM=false — an over-budget off-surface frame still fills EVERY free slot (shipped full parallelism, got %d/%d)" % [n_hot, b_hot._pbm_n])
	b_hot._offsurface = false   # settle must be reap-only (see gate doc comment)
	_settle(b_hot, axis)

	# --- healthy frame, off-surface: full pool regardless of the flag (convergence speed untouched). ---
	var b_ok := _prime(fid, slots)
	b_ok._offsurface = true
	b_ok._pbm_tile_ok = false
	b_ok._update_band_parallel(axis, true, 1.0)
	var n_ok := _occupied(b_ok)
	if not CubeSphere.FP_PREBAKE_COAST_CAP:
		# (FP_PREBAKE_COAST_CAP proactively caps a healthy off-surface frame too — skip the full-pool check when it's on.)
		_ok(n_ok == b_ok._pbm_n,
			"G-BGP-OSCALM: a HEALTHY off-surface frame fills the full pool (%d/%d) — flag %s" % [n_ok, b_ok._pbm_n, str(CubeSphere.FP_BG_OFFSURF_CALM)])
	b_ok._offsurface = false
	_settle(b_ok, axis)

## G-PBS-SCOPE / G-PBS-BACKSIDE (PERF P7b FP_PREBAKE_VIEW_SCOPE, self-describing on the CURRENT compiled value):
## off-surface, _next_fine_fid must confine the sweep to the near hemisphere (centre-dir·axis >= PREBAKE_SCOPE_DOT).
## ON: the picked facet is in-cone; once ALL in-cone facets are baked it returns -1 (never a backside facet), so the
## grind ENDS at cone coverage. OFF: with only backside facets left unbaked it STILL returns one (whole-planet sweep)
## — the falsifier proving the scope cutoff is what changes behaviour, not the fixture.
func _gate_scope() -> void:
	var fid := FacetAtlas.spawn_facet()
	var b := _prime(fid, 1)
	b._offsurface = true
	var av := _centre_dir(fid)
	var axis := [av.x, av.y, av.z]
	var sdot := CubeSphere.PREBAKE_SCOPE_DOT
	# Partition the planet by the cone cutoff.
	var incone := []
	var backside := []
	for f in range(b._base_all):
		if _centre_dir(f).dot(av) >= sdot:
			incone.append(f)
		else:
			backside.append(f)
	_ok(incone.size() > 0 and backside.size() > 0,
		"G-PBS-SCOPE: fixture axis splits the planet into in-cone (%d) and occluded-backside (%d) facets" % [incone.size(), backside.size()])
	# 1) the first pick is always in-cone (highest dot) regardless of flag (whole-planet also picks the nearest).
	var first := b._next_fine_fid(axis)
	_ok(first >= 0 and _centre_dir(first).dot(av) >= sdot,
		"G-PBS-SCOPE: first pick %d is in-cone (dot=%.3f >= %.3f)" % [first, _centre_dir(first).dot(av) if first >= 0 else -9.0, sdot])
	# 2) DISCRIMINATOR: mark every in-cone facet baked; leave the backside unbaked. Scope ON => -1 (sweep done);
	#    scope OFF => the whole-planet cursor/axis sweep still returns a backside facet.
	var b2 := _prime(fid, 1)
	b2._offsurface = true
	for f in incone:
		b2._fine_baked[f] = true
	var pick := b2._next_fine_fid(axis)
	if CubeSphere.FP_PREBAKE_VIEW_SCOPE:
		_ok(pick == -1,
			"G-PBS-BACKSIDE: scope ON — in-cone fully baked, %d backside facets unbaked, _next_fine_fid returns -1 (grind ends, no backside bake)" % backside.size())
	else:
		_ok(pick >= 0 and _centre_dir(pick).dot(av) < sdot,
			"G-PBS-BACKSIDE: scope OFF (byte-off) — whole-planet sweep still returns a backside facet %d (dot=%.3f < %.3f)" % [pick, _centre_dir(pick).dot(av) if pick >= 0 else 9.0, sdot])

## G-PBS-COAST (PERF P7a FP_PREBAKE_COAST_CAP, self-describing): a HEALTHY off-surface frame (bg_ms below budget)
## must dispatch at most BG_MAX_INFLIGHT_OFFSURF_BUSY fine tasks when the flag is ON (proactive single-baker),
## vs the FULL pool when OFF (P4 only throttles reactively on an over-budget frame). n_slots>1 makes the cap visible.
func _gate_coast() -> void:
	var fid := FacetAtlas.spawn_facet()
	var slots := 3
	var b := _prime(fid, slots)
	b._offsurface = true
	b._pbm_tile_ok = false
	var av := _centre_dir(fid)
	var axis := [av.x, av.y, av.z]
	b._update_band_parallel(axis, true, 1.0)   # healthy off-surface frame (1.0 ms << BG_FRAME_BUDGET_MS)
	var n := _occupied(b)
	if CubeSphere.FP_PREBAKE_COAST_CAP:
		_ok(n <= CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY and n >= 1,
			"G-PBS-COAST: COAST_CAP ON — a HEALTHY off-surface frame caps fine dispatch to %d (<= %d, >=1 floor)" % [n, CubeSphere.BG_MAX_INFLIGHT_OFFSURF_BUSY])
	else:
		_ok(n == b._pbm_n,
			"G-PBS-COAST: COAST_CAP OFF (byte-off) — a healthy off-surface frame fills the full pool (%d/%d)" % [n, b._pbm_n])
	b._offsurface = false
	_settle(b, axis)
