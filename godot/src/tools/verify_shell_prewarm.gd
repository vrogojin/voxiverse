extends SceneTree
## COSMOS DE-ORBIT SHELL PRE-WARM gate (docs/COSMOS-DEORBIT-SHELL-PREWARM-DESIGN.md §8, FP_SHELL_PREWARM_DESCENT) —
## proves the descent pre-warm: while off-surface + analytically descending inside [SHELL_PWD_ALT_LO, SHELL_PWD_ALT_HI]
## the far-ring shell's sector residency is BUILT AHEAD of the S1 anchor-release knee — paced cap snapshots keep the
## wanted set current, and the shipped FP_SHELL_STAGE_REEMIT run builds it with ONE scoped relaxation: class-0 GROWTH
## is budget-eligible during an engaged (voluntary) pre-warm dispatch (E8). By the knee the sectors are resident+current,
## so the release dirty set is a small class-1 replacement — the one-shot 927-facet/1.07M-prim dlmalloc convoy never forms.
##
## Per the C-lite/staging RUNTIME-DEAD lesson, this gate drives the REAL law through the codebase's forcing params
## (`_pwd_tick(h, on := true)`, `_stage_filter_dirty(axis, stage_on := true)` reading the frozen `_async_prewarm`, the
## pure `shell_prewarm_snap_due`) — NO sed of the NEW flag FP_SHELL_PREWARM_DESCENT (its default-false byte-off is proven
## by G-PWD-BYTEOFF + the FLAT 6042/0 gate). The `_pwd_tick` composition-floor and the staging machinery are compile
## consts, so this gate DOES sed the already-deployed stack the design's §2 "Requires" clause names.
##
## RUN (needs FACETED + FP_FARRING_SECTORS + FP_SHELL_STAGE_REEMIT + FP_FARRING_FULL_COVER — the sectors/staging floor
## `_pwd_tick` hard-references, and FULL_COVER so `_sector_sig_sunkish` is reachable for the knee gate; all deployed flags):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_SECTORS := false/const FP_FARRING_SECTORS := true/;s/const FP_SHELL_STAGE_REEMIT := false/const FP_SHELL_STAGE_REEMIT := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_shell_prewarm.gd
##   then REVERT the sed + re-import. Exits 0 all-pass / 1 on any failure. FP_SHELL_PREWARM_DESCENT stays DEFAULT-FALSE.
##
## Sub-gates: G-PWD-ENGAGE, G-PWD-PACE, G-PWD-BUDGET (load-bearing — FAILS on the shipped class-0 exemption), G-PWD-RESIDENT,
## G-PWD-KNEE, G-PWD-NOHOLE, G-PWD-CALM, G-PWD-BYTEOFF.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

const ORBIT_D_ADD := 6000.0     # orbit-band cap for the burst gates (a substantial multi-sector open)

var _pass := 0
var _fail := 0
var _R := 0.0
var _active := 0

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_shell_prewarm (COSMOS DE-ORBIT SHELL PRE-WARM — FP_SHELL_PREWARM_DESCENT) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true (see the RUN header).")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not (CubeSphere.FP_FARRING_SECTORS and CubeSphere.FP_SHELL_STAGE_REEMIT):
		print("  FAIL: FP_FARRING_SECTORS / FP_SHELL_STAGE_REEMIT are OFF — the pre-warm composition floor (`_pwd_tick`) needs them sedded on (see the RUN header).")
		print("==== VERIFY: %d passed, 1 failed ====" % _pass); quit(1); return
	TC.warm_up()
	FA.warm_up()
	_R = FA.R_BLOCKS
	_active = FA.spawn_facet()
	TC.set_active_facet(_active)
	print("  atlas: k=%d, R=%.0f, active=%d ; ALT[%.0f,%.0f] SAMPLE=%d SNAP=%d DRIFT=%.1f DTH=%.1f ; TRIGGER=%d BUDGET=%d ; FULL_COVER=%s PREWARM=%s SRC_PREWARM=%d SRC_COUNT=%d" % [
		FA.K, _R, _active, CubeSphere.SHELL_PWD_ALT_LO, CubeSphere.SHELL_PWD_ALT_HI, CubeSphere.SHELL_PWD_SAMPLE_MS,
		CubeSphere.SHELL_PWD_SNAP_MS, CubeSphere.SHELL_PWD_DRIFT_DEG, CubeSphere.SHELL_PWD_DTH_DEG,
		CubeSphere.SHELL_STAGE_TRIGGER, CubeSphere.SHELL_STAGE_FACETS, str(CubeSphere.FP_FARRING_FULL_COVER),
		str(CubeSphere.FP_SHELL_PREWARM_DESCENT), FFR.SRC_PREWARM, FFR.SRC_COUNT])

	_gate_engage()
	_gate_pace()
	_gate_budget()
	_gate_resident()
	_gate_knee()
	_gate_nohole()
	_gate_calm()
	_gate_byteoff()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------- helpers ----------------

func _fresh_ring() -> Node3D:
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", _active)
	return ring

## The base sub-camera direction (the active facet's normal).
func _base_dir() -> Vector3:
	var nrm := FA.facet_normal64(_active)
	return Vector3(nrm[0], nrm[1], nrm[2]).normalized()

## Rotate `c` by `deg` degrees about an axis perpendicular to it (deterministic).
func _rot(c: Vector3, deg: float) -> Vector3:
	var up := Vector3.UP
	if absf(c.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var p := c.cross(up).normalized()
	var a := deg_to_rad(deg)
	return (c * cos(a) + p * sin(a)).normalized()

## Engage the camera-set law state without a build: off-surface orbit regime (`_shell_orbit()` true).
func _camset(ring: Node3D, floored := false) -> void:
	ring.set("_cam_set", true)
	ring.set("_emit_floored_last", floored)

## Model the real COLLAPSED orbit residency: the shell is SECTORED (its last orbit-era build was per-sector), so the
## whole-cap `_mi` holds NO surfaces. `setup()` does a one-shot SYNC whole-cap build for the gate fixture; empty it so
## `pwd_growth_ok` is reachable (in production `_swap_in_sectors` clears `_mi` on the first sectored swap). The sectors
## stay never-built (epoch-stale) ⇒ the wanted set is a class-0 GROWTH open — exactly the pre-warm's job.
func _empty_mi(ring: Node3D) -> void:
	(ring.get("_mi") as MeshInstance3D).mesh = ArrayMesh.new()

## One WALL-spaced descent-latch sample through the REAL `_pwd_tick(h, on := true)`.
func _latch(ring: Node3D, h: float) -> void:
	OS.delay_msec(CubeSphere.SHELL_PWD_SAMPLE_MS + 12)
	ring.call("_pwd_tick", h, true)

func _dict_keyset(d: Dictionary) -> Dictionary:
	var s := {}
	for k in d.keys():
		s[int(k)] = true
	return s

func _int_set(arr: PackedInt32Array) -> Dictionary:
	var s := {}
	for v in arr:
		s[int(v)] = true
	return s

func _superset(a: Dictionary, b: Dictionary) -> bool:   # a ⊇ b ?
	for k in b.keys():
		if not a.has(k):
			return false
	return true

func _same_keyset(a: Dictionary, b: Dictionary) -> bool:
	return a.size() == b.size() and _superset(a, b) and _superset(b, a)

## Per-sector facet counts for a fid set (via the ring's real `_sector_of`).
func _sector_counts(ring: Node3D, vis: PackedInt32Array) -> Dictionary:
	var d := {}
	for f in vis:
		var s := int(ring.call("_sector_of", int(f)))
		d[s] = int(d.get(s, 0)) + 1
	return d

## The union of every sector's drawn shard (`_sector_drawn`) — the drawn set the swap would present.
func _drawn_union(ring: Node3D) -> Dictionary:
	var u := {}
	var sd: Array = ring.get("_sector_drawn")
	for s in range(sd.size()):
		var shard = sd[s]
		if shard is Dictionary:
			for fid in (shard as Dictionary).keys():
				u[int(fid)] = true
	return u

## Freeze `vis` as the dispatch fid-set + engage the sectored/pre-warm mode (the E7 freeze, forced on).
func _freeze_prewarm_inputs(ring: Node3D, vis: PackedInt32Array, backstop: Dictionary) -> void:
	ring.set("_async_fids", vis)
	ring.set("_async_sectored", true)
	ring.set("_async_backstop", backstop)
	ring.set("_async_prewarm", true)

## ONE manual pre-warm drain cycle on the REAL functions (E7 freeze → compute-dirty → E8 stage-filter → record swap).
## Returns [slice, deferred]. `_async_prewarm` is re-frozen true each cycle (the flag-off gate can't get it via E7).
func _pwd_cycle(ring: Node3D, axis: Vector3) -> Array:
	ring.set("_async_prewarm", true)
	ring.call("_sectors_compute_dirty", true)
	ring.call("_stage_filter_dirty", axis, true)
	var slice := int(ring.get("_stage_last_emit_facets"))
	var deferred := int(ring.get("_stage_deferred_n"))
	ring.call("_sectors_record_frozen")             # swap: record the KEPT (still-dirty) sectors at the current epoch
	if int(ring.get("_stage_deferred_n")) == 0:     # mirror _poll_async_rebuild's SRC_STAGE run-close
		ring.set("_stage_active", false)
		ring.set("_stage_hold", [])
	return [slice, deferred]

# ---------------- G-PWD-ENGAGE ----------------
## Latch/predicate truth table on the REAL `_pwd_tick`: steady & climb never engage; a real descent engages within 2
## samples once in-band and disengages below the band + on the floored flip; a teleport sample is VY_CLAMP-rejected.
func _gate_engage() -> void:
	print("  --- G-PWD-ENGAGE: descent latch + engage predicate truth table (REAL _pwd_tick, wall-clock sampled) ---")
	# (A) steady, in-band: Δh = 0 ⇒ never descending, never active.
	var a := _fresh_ring(); _camset(a)
	_latch(a, 1000.0)   # baseline
	for _i in range(3):
		_latch(a, 1000.0)
	_ok(not bool(a.get("_pwd_descending")) and not bool(a.get("_pwd_active")),
		"G-PWD-ENGAGE: steady in-band h ⇒ latch never engages (desc=%s active=%s)" % [str(a.get("_pwd_descending")), str(a.get("_pwd_active"))])
	a.free()
	# (B) climb through the band: Δh > 0 ⇒ never descending, never active.
	var b := _fresh_ring(); _camset(b)
	_latch(b, 900.0)
	for hb in [960.0, 1020.0, 1080.0]:
		_latch(b, hb)
	_ok(not bool(b.get("_pwd_descending")) and not bool(b.get("_pwd_active")),
		"G-PWD-ENGAGE: a climb through the band never engages (desc=%s active=%s)" % [str(b.get("_pwd_descending")), str(b.get("_pwd_active"))])
	b.free()
	# (C) real descent: engages within 2 samples once h ≤ HI, disengages below LO and on the floored flip.
	var c := _fresh_ring(); _camset(c)
	_latch(c, 1400.0)                       # baseline (above band)
	_latch(c, 1340.0)                       # sample 1: steep descent ⇒ latch descends; h > HI ⇒ not active yet
	_ok(bool(c.get("_pwd_descending")), "G-PWD-ENGAGE: descent latched within the first sample (desc=%s)" % str(c.get("_pwd_descending")))
	_ok(not bool(c.get("_pwd_active")), "G-PWD-ENGAGE: above the band (h=1340 > HI) ⇒ not engaged yet")
	_latch(c, 1290.0)                       # sample 2: in band ⇒ engages (rising edge seeds a snapshot)
	_ok(bool(c.get("_pwd_active")) and bool(c.get("_pwd_snap_due")),
		"G-PWD-ENGAGE: in-band descent engages + seeds the rising-edge snapshot (active=%s snap_due=%s)" % [str(c.get("_pwd_active")), str(c.get("_pwd_snap_due"))])
	_latch(c, 620.0)                        # below the band floor
	_ok(bool(c.get("_pwd_descending")) and not bool(c.get("_pwd_active")),
		"G-PWD-ENGAGE: below LO the knee machinery owns it ⇒ disengaged though still descending")
	# floored flip: back in-band re-engages, then the surface floor (_shell_orbit false) disengages.
	_latch(c, 1000.0)
	_ok(bool(c.get("_pwd_active")), "G-PWD-ENGAGE: back in-band while descending ⇒ re-engaged")
	c.set("_emit_floored_last", true)       # OFFSURFACE_Y floor flip ⇒ _shell_orbit() false
	_latch(c, 1000.0)
	_ok(not bool(c.get("_pwd_active")), "G-PWD-ENGAGE: the floored flip (_shell_orbit false) disengages pre-warm")
	c.free()
	# (D) teleport clamp: a single |vy| > VY_CLAMP sample is rejected — the latch does NOT descend.
	var d := _fresh_ring(); _camset(d)
	_latch(d, 1000.0)                       # baseline
	_latch(d, 200.0)                        # Δh = −800 over ~0.26 s ⇒ vy ≈ −3000 b/s > VY_CLAMP ⇒ rejected
	_ok(not bool(d.get("_pwd_descending")),
		"G-PWD-ENGAGE: a teleport-magnitude sample is VY_CLAMP-rejected (desc stays %s)" % str(d.get("_pwd_descending")))
	d.free()

# ---------------- G-PWD-PACE ----------------
## The paced-snapshot bound is the PURE decision `shell_prewarm_snap_due` — the exact function E6 calls to gate a forced
## snapshot: a rising-edge override, a ≥ SNAP_MS spacing floor, and the drift/Δθ_h thresholds. Driven directly with
## synthetic inputs (its `shell_fall_should_reemit` precedent). The E6 wiring that increments `_pwd_snap_count` is behind
## the compiled FP_SHELL_PREWARM_DESCENT (no forcing param — like E7/E8's `_async_prewarm` freeze) and is the live-A/B
## consumer; here we pin the decision law it consumes, which is where every pacing bound actually lives.
func _gate_pace() -> void:
	print("  --- G-PWD-PACE: the paced-snapshot decision law shell_prewarm_snap_due (spacing floor + thresholds) ---")
	var snap_ms := CubeSphere.SHELL_PWD_SNAP_MS
	var big_drift := deg_to_rad(CubeSphere.SHELL_PWD_DRIFT_DEG + 1.0)
	var big_dth := deg_to_rad(CubeSphere.SHELL_PWD_DTH_DEG + 0.5)
	var small := deg_to_rad(0.1)
	_ok(bool(FFR.shell_prewarm_snap_due(true, 0, 0.0, 0.0)),
		"G-PWD-PACE: rising edge forces a snapshot regardless of elapsed/thresholds")
	_ok(not bool(FFR.shell_prewarm_snap_due(false, snap_ms - 1, big_drift, big_dth)),
		"G-PWD-PACE: elapsed < SNAP_MS ⇒ no snapshot even past the thresholds (the spacing bound)")
	_ok(bool(FFR.shell_prewarm_snap_due(false, snap_ms, big_drift, 0.0)),
		"G-PWD-PACE: elapsed ≥ SNAP_MS AND drift ≥ DRIFT_DEG ⇒ snapshot")
	_ok(bool(FFR.shell_prewarm_snap_due(false, snap_ms, 0.0, big_dth)),
		"G-PWD-PACE: elapsed ≥ SNAP_MS AND |Δθ_h| ≥ DTH_DEG ⇒ snapshot")
	_ok(not bool(FFR.shell_prewarm_snap_due(false, snap_ms, deg_to_rad(CubeSphere.SHELL_PWD_DRIFT_DEG - 0.1), deg_to_rad(CubeSphere.SHELL_PWD_DTH_DEG - 0.1))),
		"G-PWD-PACE: elapsed ≥ SNAP_MS but drift & Δθ_h just under threshold ⇒ silent")
	_ok(not bool(FFR.shell_prewarm_snap_due(false, snap_ms + 200, small, small)),
		"G-PWD-PACE: elapsed ≥ SNAP_MS but sub-threshold drift & Δθ_h ⇒ silent (no-op tick is free)")

# ---------------- G-PWD-BUDGET (load-bearing) ----------------
## From a COLLAPSED residency (fresh instance — every sector never-built ⇒ class-0 GROWTH), an engaged pre-warm dispatch
## (`_async_prewarm` frozen true) STAGES the growth burst: the emitted slice ∈ [1, max(BUDGET, largest sector)]. This is
## the exact assertion the live knee failed — it FAILS on the shipped class-0 exemption (E8 makes growth budget-eligible).
func _gate_budget() -> void:
	print("  --- G-PWD-BUDGET: the class-0 GROWTH burst is BUDGETED under an engaged pre-warm (E8 load-bearing) ---")
	var ring := _fresh_ring()
	var c := _base_dir()
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], _R + ORBIT_D_ADD, false)
	var vis: PackedInt32Array = ring.call("visible_fids")
	for f in vis:
		ring.call("_ensure_cached", int(f))          # give every facet cache content (sectors gain members)
	_empty_mi(ring)                                  # collapsed orbit residency: the cap is sectored, `_mi` empty
	_ok(vis.size() > CubeSphere.SHELL_STAGE_TRIGGER,
		"G-PWD-BUDGET: the collapsed-orbit open is a real burst (%d facets > TRIGGER %d)" % [vis.size(), CubeSphere.SHELL_STAGE_TRIGGER])
	var counts := _sector_counts(ring, vis)
	var max_sector := 0
	for s in counts.keys():
		max_sector = maxi(max_sector, int(counts[s]))
	var hard_bound: int = maxi(CubeSphere.SHELL_STAGE_FACETS, max_sector)
	# pwd_growth_ok requires the whole-cap `_mi` to hold NO surfaces (the sectored-orbit state): assert that precondition.
	var mi = ring.get("_mi")
	_ok(mi != null and (mi as MeshInstance3D).mesh != null and ((mi as MeshInstance3D).mesh as ArrayMesh).get_surface_count() == 0,
		"G-PWD-BUDGET: the whole-cap `_mi` holds no surfaces ⇒ pwd_growth_ok is reachable")
	# freeze the dispatch (E7) with pre-warm engaged, then run the REAL E8 filter directly (flag-off ⇒ E7 can't set it).
	_freeze_prewarm_inputs(ring, vis, {})
	ring.call("_sectors_compute_dirty", true)
	var pre_dirty := int((ring.get("_async_sector_dirty") as Dictionary).size())
	var sax: Array = ring.call("_cull_params")[0]
	var axis := Vector3(sax[0], sax[1], sax[2])
	ring.call("_stage_filter_dirty", axis, true)
	var slice := int(ring.get("_stage_last_emit_facets"))
	var deferred := int(ring.get("_stage_deferred_n"))
	_ok(deferred > 0,
		"G-PWD-BUDGET: the growth burst STAGED (deferred=%d > 0) — class-0 growth was admitted to the budget (FAILS on the shipped exemption)" % deferred)
	_ok(slice >= 1 and slice <= hard_bound,
		"G-PWD-BUDGET: the emitted slice ∈ [1, max(BUDGET=%d, largest-sector=%d)=%d] (slice=%d) — growth is bounded, not a 927-facet avalanche" % [CubeSphere.SHELL_STAGE_FACETS, max_sector, hard_bound, slice])
	# cross-check: the slice == the sum of member counts of the sectors still dirty after the filter.
	var dirty: Dictionary = ring.get("_async_sector_dirty")
	var sum := 0
	for s in dirty.keys():
		sum += int(counts.get(int(s), 0))
	_ok(sum == slice and pre_dirty > dirty.size(),
		"G-PWD-BUDGET: slice == Σ member-counts of the kept sectors (%d==%d) and sectors were genuinely deferred (%d → %d)" % [sum, slice, pre_dirty, dirty.size()])
	ring.free()

# ---------------- G-PWD-RESIDENT ----------------
## The engaged pre-warm drain converges: it stages across multiple cycles, every slice is budgeted, and by convergence
## the residency == the wanted set (the drawn union == the full visible cap) with an empty/sub-trigger dirty set.
func _gate_resident() -> void:
	print("  --- G-PWD-RESIDENT: the paced growth drain converges to full residency (== the wanted set) ---")
	var ring := _fresh_ring()
	var c := _base_dir()
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], _R + ORBIT_D_ADD, false)
	var vis: PackedInt32Array = ring.call("visible_fids")
	for f in vis:
		ring.call("_ensure_cached", int(f))
	_empty_mi(ring)                                  # collapsed orbit residency (sectored cap, `_mi` empty)
	var counts := _sector_counts(ring, vis)
	var max_sector := 0
	for s in counts.keys():
		max_sector = maxi(max_sector, int(counts[s]))
	var hard_bound: int = maxi(CubeSphere.SHELL_STAGE_FACETS, max_sector)
	_freeze_prewarm_inputs(ring, vis, {})
	var sax: Array = ring.call("_cull_params")[0]
	var axis := Vector3(sax[0], sax[1], sax[2])
	var cap := 4 * (vis.size() / maxi(1, CubeSphere.SHELL_STAGE_FACETS)) + 16
	var cycles := 0
	var budget_ok := true
	var mono_ok := true
	var drained := false
	var prev_union := {}
	while cycles < cap:
		var r := _pwd_cycle(ring, axis)
		var slice := int(r[0])
		var deferred := int(r[1])
		if slice < 1 or slice > hard_bound:
			budget_ok = false
		# NO-HOLE (intra-drain): the drawn union only grows — never loses a facet it drew before.
		var u := _drawn_union(ring)
		if not _superset(u, prev_union):
			mono_ok = false
		prev_union = u
		cycles += 1
		if deferred == 0:
			drained = true
			break
	_ok(drained, "G-PWD-RESIDENT: the pre-warm run DRAINED (nothing deferred on the last cycle) in %d cycles" % cycles)
	_ok(cycles >= 2, "G-PWD-RESIDENT: the burst genuinely staged across multiple cycles (%d)" % cycles)
	_ok(budget_ok, "G-PWD-RESIDENT: every drained slice stayed within [1, %d] (no moved stall)" % hard_bound)
	_ok(mono_ok, "G-PWD-RESIDENT: the drawn union grew monotonically through the drain (no intermediate hole)")
	# residency == wanted: the final drawn union == the full visible cap.
	var final_union := _drawn_union(ring)
	_ok(_same_keyset(final_union, _int_set(vis)),
		"G-PWD-RESIDENT: at convergence the residency == the wanted set (drawn union %d == visible %d)" % [final_union.size(), vis.size()])
	# and a fresh dirty recompute against the same inputs yields nothing (≤ trigger).
	ring.set("_async_prewarm", true)
	ring.call("_sectors_compute_dirty", true)
	var resid_dirty := int((ring.get("_async_sector_dirty") as Dictionary).size())
	_ok(resid_dirty == 0,
		"G-PWD-RESIDENT: the converged residency recomputes to an EMPTY dirty set (%d) — the knee sees no growth" % resid_dirty)
	ring.free()

# ---------------- G-PWD-KNEE ----------------
## After a converged pre-warm residency the release-knee delta is SMALL: a sunk-only knee change (unsink column move +
## _applied_r 0→APPLIED_PROBE_MAX) re-dirties ONLY the sunkish disc, staged ≤ budget — no 927-facet dispatch ever forms.
func _gate_knee() -> void:
	print("  --- G-PWD-KNEE: post-residency, the sunk-only knee change is a SMALL class-1 replacement (no big dispatch) ---")
	if not CubeSphere.FP_FARRING_FULL_COVER:
		_ok(false, "G-PWD-KNEE: FP_FARRING_FULL_COVER is OFF — sed it on so sunkish sectors are reachable (see the RUN header)")
		return
	var ring := _fresh_ring()
	# a sunkish fid set spanning ≥ 2 sectors: a whole face's facets, dense+coarse cached (sig bits 1&2), in the backstop set.
	var k := FA.K
	var face := int(_active / (k * k))
	var fids := PackedInt32Array()
	for a in range(k):
		for b in range(k):
			fids.append((face * k + a) * k + b)
	var backstop := {}
	for f in fids:
		ring.call("_ensure_cached", int(f))
		ring.call("_ensure_backstop_cached", int(f))
		backstop[int(f)] = true
	_empty_mi(ring)                                  # collapsed orbit residency (sectored cap, `_mi` empty)
	var counts := _sector_counts(ring, fids)
	var max_sector := 0
	for s in counts.keys():
		max_sector = maxi(max_sector, int(counts[s]))
	var hard_bound: int = maxi(CubeSphere.SHELL_STAGE_FACETS, max_sector)
	_freeze_prewarm_inputs(ring, fids, backstop)
	# knee-state A (pre-warm era): a valid unsink column, applied cover still 0 (above the near re-grow).
	ring.set("_async_unsink_col", Vector3(_R, 0.0, 0.0))
	ring.set("_async_unsink_have_col", true)
	ring.set("_async_applied_r", 0.0)
	var sax: Array = ring.call("_cull_params")[0]
	var axis := Vector3(sax[0], sax[1], sax[2])
	# drain the pre-warm residency; track the max slice — no dispatch may exceed the budget bound.
	var cap := 4 * (fids.size() / maxi(1, CubeSphere.SHELL_STAGE_FACETS)) + 16
	var cycles := 0
	var max_slice := 0
	while cycles < cap:
		var r := _pwd_cycle(ring, axis)
		max_slice = maxi(max_slice, int(r[0]))
		cycles += 1
		if int(r[1]) == 0:
			break
	var sunkish_total := fids.size()
	ring.set("_async_prewarm", true)
	ring.call("_sectors_compute_dirty", true)
	_ok(int((ring.get("_async_sector_dirty") as Dictionary).size()) == 0,
		"G-PWD-KNEE: the sunkish shell is fully resident after pre-warm (empty dirty pre-knee)")
	# THE KNEE (pre-warm now DISENGAGED — the knee machinery owns it): the sunk-only near re-grow mutation.
	ring.set("_async_prewarm", false)
	ring.set("_async_unsink_col", Vector3(_R + 40.0, 6.0, 0.0))    # unsink column moved (the re-grow)
	ring.set("_async_applied_r", float(CubeSphere.APPLIED_PROBE_MAX))  # applied cover climbs 0 → 112
	ring.call("_sectors_compute_dirty", true)
	var knee_dirty: Dictionary = ring.get("_async_sector_dirty")
	var knee_facets := 0
	for s in knee_dirty.keys():
		knee_facets += int(counts.get(int(s), 0))
	_ok(knee_dirty.size() >= 1 and knee_facets <= sunkish_total,
		"G-PWD-KNEE: the knee re-dirties ONLY the sunkish disc (%d sectors / %d facets ≤ %d) — not the whole cap" % [knee_dirty.size(), knee_facets, sunkish_total])
	ring.call("_stage_filter_dirty", axis, true)
	var knee_slice := int(ring.get("_stage_last_emit_facets"))
	# no dispatch anywhere in the run history (pre-warm drain OR the knee) exceeded the budget bound.
	_ok(max_slice <= hard_bound and knee_slice <= hard_bound,
		"G-PWD-KNEE: NO dispatch in the whole run (pre-warm max=%d, knee=%d) exceeded max(BUDGET,sector)=%d — the 927-facet convoy never forms" % [max_slice, knee_slice, hard_bound])
	ring.free()

# ---------------- G-PWD-NOHOLE ----------------
## The `_mi`-resident exemption holds: when the whole-cap `_mi` still owns surfaces (a resident sync build), pwd_growth_ok
## is FALSE even with pre-warm engaged, so class-0 growth keeps the shipped exemption (its coverage is in a mesh the swap clears).
func _gate_nohole() -> void:
	print("  --- G-PWD-NOHOLE: while `_mi` holds surfaces the class-0 exemption HOLDS (pwd_growth_ok false) ---")
	var ring := _fresh_ring()
	var c := _base_dir()
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], _R + ORBIT_D_ADD, false)
	var vis: PackedInt32Array = ring.call("visible_fids")
	for f in vis:
		ring.call("_ensure_cached", int(f))
	# make the whole-cap `_mi` hold a real surface (a resident sync build state).
	var mi := ring.get("_mi") as MeshInstance3D
	var am := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = am
	_ok((mi.mesh as ArrayMesh).get_surface_count() > 0, "G-PWD-NOHOLE: `_mi` now holds surfaces (resident sync-build state)")
	# engage pre-warm (E7 freeze) over a collapsed (never-built) residency, then run the REAL E8 filter.
	_freeze_prewarm_inputs(ring, vis, {})
	ring.call("_sectors_compute_dirty", true)
	var sax: Array = ring.call("_cull_params")[0]
	ring.call("_stage_filter_dirty", Vector3(sax[0], sax[1], sax[2]), true)
	# pwd_growth_ok is false (mi holds surfaces) ⇒ class-0 growth is EXEMPT ⇒ nothing is deferred, nothing staged.
	_ok(int(ring.get("_stage_deferred_n")) == 0 and int(ring.get("_stage_last_emit_facets")) == 0,
		"G-PWD-NOHOLE: `_mi`-resident ⇒ growth stays class-0 exempt (deferred=%d, staged emit=%d) — the swap's clear can't drop coverage" % [int(ring.get("_stage_deferred_n")), int(ring.get("_stage_last_emit_facets"))])
	ring.free()

# ---------------- G-PWD-CALM ----------------
## Steady-orbit soak: constant in-band h + constant axis ⇒ the latch never descends, pre-warm never engages, and zero
## forced snapshots / zero dispatch arms occur — the FP_UNSINK_DRIFT_CALM no-churn contract, asserted not argued.
func _gate_calm() -> void:
	print("  --- G-PWD-CALM: a steady-orbit soak forces zero snapshots / zero engagement (no-churn contract) ---")
	var ring := _fresh_ring()
	var c := _base_dir()
	var d := _R + ORBIT_D_ADD
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], d, false)   # engage the camera-set law (one SRC_CAM snapshot)
	var base_snaps := int(ring.get("_snapshot_count"))
	ring.set("_pwd_snap_count", 0)
	var active_ever := false
	# soak: several SAMPLE_MS windows of constant h + constant axis through the REAL tick + camera-set path.
	for _i in range(6):
		OS.delay_msec(CubeSphere.SHELL_PWD_SAMPLE_MS + 12)
		ring.call("_pwd_tick", 1000.0, true)
		ring.call("shell_set_camera_abs", [c.x, c.y, c.z], d, false)
		if bool(ring.get("_pwd_active")):
			active_ever = true
	_ok(not active_ever and not bool(ring.get("_pwd_descending")),
		"G-PWD-CALM: constant-h in-band soak never engages the latch (_pwd_active stayed false throughout)")
	_ok(int(ring.get("_pwd_snap_count")) == 0,
		"G-PWD-CALM: zero pre-warm-forced snapshots over the soak (count=%d)" % int(ring.get("_pwd_snap_count")))
	_ok(int(ring.get("_snapshot_count")) == base_snaps,
		"G-PWD-CALM: no re-emit snapshot armed by pre-warm during the soak (snapshot_count %d unchanged)" % base_snaps)
	ring.free()

# ---------------- G-PWD-BYTEOFF ----------------
## on = false (the compiled default): the REAL `_pwd_tick(h, false)` early-returns — every _pwd_* stays at its zero
## initializer — and an OFF (`_async_prewarm` false) `_stage_filter_dirty` reproduces the shipped class-0 exemption verbatim.
func _gate_byteoff() -> void:
	print("  --- G-PWD-BYTEOFF: on=false ⇒ _pwd_* never leave zero + the shipped class-0 partition verbatim ---")
	var ring := _fresh_ring(); _camset(ring)
	# a full descent driven with on=false: no sampling, no latch, no engage.
	for h in [1400.0, 1300.0, 1100.0, 900.0, 700.0]:
		OS.delay_msec(CubeSphere.SHELL_PWD_SAMPLE_MS + 12)
		ring.call("_pwd_tick", h, false)
	_ok(not bool(ring.get("_pwd_descending")) and not bool(ring.get("_pwd_active"))
			and int(ring.get("_pwd_snap_count")) == 0 and int(ring.get("_pwd_prev_ms")) == -1
			and not bool(ring.get("_pwd_snap_due")),
		"G-PWD-BYTEOFF: on=false ⇒ all _pwd_* stay at zero (desc=%s active=%s snaps=%d prev_ms=%d snap_due=%s)" % [
			str(ring.get("_pwd_descending")), str(ring.get("_pwd_active")), int(ring.get("_pwd_snap_count")),
			int(ring.get("_pwd_prev_ms")), str(ring.get("_pwd_snap_due"))])
	ring.free()
	# the OFF partition: `_async_prewarm` false over a collapsed growth burst ⇒ class-0 exempt ⇒ nothing deferred/staged
	# (element-equal to a FP_SHELL_PREWARM_DESCENT-absent reference: the shipped staging exemption).
	var r2 := _fresh_ring()
	var c := _base_dir()
	r2.call("shell_set_camera_abs", [c.x, c.y, c.z], _R + ORBIT_D_ADD, false)
	var vis: PackedInt32Array = r2.call("visible_fids")
	for f in vis:
		r2.call("_ensure_cached", int(f))
	r2.set("_async_fids", vis)
	r2.set("_async_sectored", true)
	r2.set("_async_backstop", {})
	r2.set("_async_prewarm", false)               # pre-warm OFF ⇒ the shipped partition
	r2.call("_sectors_compute_dirty", true)
	var pre := int((r2.get("_async_sector_dirty") as Dictionary).size())
	var sax: Array = r2.call("_cull_params")[0]
	r2.call("_stage_filter_dirty", Vector3(sax[0], sax[1], sax[2]), true)
	_ok(pre > 0 and int(r2.get("_stage_deferred_n")) == 0 and int(r2.get("_stage_last_emit_facets")) == 0
			and int((r2.get("_async_sector_dirty") as Dictionary).size()) == pre,
		"G-PWD-BYTEOFF: `_async_prewarm` false ⇒ class-0 growth stays exempt (deferred=0, emit=0, dirty %d unchanged) — shipped partition verbatim" % pre)
	r2.free()
