extends SceneTree
## COSMOS DE-ORBIT SHELL STAGING gate (docs/COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md §8, FP_SHELL_STAGE_REEMIT) — proves
## the release-knee re-emit-avalanche stager: a dirty burst > SHELL_STAGE_TRIGGER far-ring facets is released over
## multiple worker cycles at ≤ SHELL_STAGE_FACETS facets/dispatch, nearest-camera-first, from ONE held input snapshot,
## converging to the IDENTICAL final shell with no hole and no stale sunk-wedge.
##
## Per the C-lite lesson (a fix can be RUNTIME-DEAD), this gate drives the REAL dispatch → WorkerThreadPool build →
## sectored swap path — NOT a mirror. It calls `_dispatch_async_rebuild(sectored_on, stage_on)` directly (sidestepping
## the compile-const `_async_enabled()` / FP_FARRING_ASYNC_REBUILD baked value) with the codebase-convention forcing
## params, so NO sed of FP_SHELL_STAGE_REEMIT or FP_FARRING_SECTORS is needed — the gate drives both the staged
## (stage_on=true) and the byte-off (stage_on=false) arms itself, then spins `_poll_async_rebuild` to run the real swap.
##
## RUN (needs FACETED + FP_FARRING_FULL_COVER — the latter because `_sector_sig_sunkish` bit-1 is a COMPILE const gated
## on FULL_COVER, and the SUNKPIN regression can only manifest with sunkish sectors; FULL_COVER is a deployed flag so
## this also models the live knee set):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_shell_staging.gd
##   then REVERT the sed + re-import. Exits 0 all-pass / 1 on any failure.
##
## Sub-gates: G-STG-TRIG, G-STG-BUDGET, G-STG-CONVERGE, G-STG-MERGE, G-STG-SUNKPIN, G-STG-NOHOLE, G-STG-HOLD,
## G-STG-FAILSAFE, G-STG-BYTEOFF.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

const ORBIT_D_ADD := 6000.0     # altitude above R for the orbit-band dispatch gates (a substantial multi-sector cap)

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
	print("=== verify_shell_staging (COSMOS DE-ORBIT SHELL STAGING — FP_SHELL_STAGE_REEMIT) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TC.warm_up()
	FA.warm_up()
	_R = FA.R_BLOCKS
	_active = FA.spawn_facet()
	TC.set_active_facet(_active)
	print("  atlas: k=%d, R=%.0f, active=%d, TRIGGER=%d, BUDGET=%d, MAX_MS=%d, FULL_COVER=%s, SECTORS=%s, STAGE=%s" % [
		FA.K, _R, _active, CubeSphere.SHELL_STAGE_TRIGGER, CubeSphere.SHELL_STAGE_FACETS, CubeSphere.SHELL_STAGE_MAX_MS,
		str(CubeSphere.FP_FARRING_FULL_COVER), str(CubeSphere.FP_FARRING_SECTORS), str(CubeSphere.FP_SHELL_STAGE_REEMIT)])

	_gate_trig()
	_gate_budget_converge_nohole()
	_gate_merge()
	_gate_sunkpin()
	_gate_hold()
	_gate_failsafe()
	_gate_byteoff()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------- driver helpers (the REAL path, not mirrors) ----------------

## Spin the real poll until the in-flight worker build has completed + swapped.
func _drain_worker(ring: Node3D) -> void:
	var guard := 0
	while bool(ring.get("_async_building")) and guard < 200000:
		ring.call("_poll_async_rebuild")
		OS.delay_msec(1)
		guard += 1

## Real dispatch + drain. sectored/stage forced via the codebase-convention params.
func _dispatch(ring: Node3D, sectored: bool, stage: bool) -> void:
	ring.call("_dispatch_async_rebuild", sectored, stage)
	_drain_worker(ring)

## A fresh far-ring engaged over the active facet at orbit altitude `d`, coarse caches prewarmed over the visible cap,
## with a first REFERENCE build (sectored, un-staged) recorded. `_bpos_cache` is deliberately LEFT COLD so a later
## `_ensure_backstop_cached` sweep flips signature bit-2 on every facet ⇒ every sector dirties (the burst).
func _prep_ring(d: float) -> Node3D:
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", _active)
	var nrm := FA.facet_normal64(_active)
	var c := Vector3(nrm[0], nrm[1], nrm[2]).normalized()
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], d, false)   # off-surface orbit regime
	var vis: PackedInt32Array = ring.call("visible_fids")
	for f in vis:
		ring.call("_ensure_cached", int(f))
	_dispatch(ring, true, false)    # reference build: all sectors resident at the current epoch
	return ring

## Flip signature bit-2 on every visible facet (warm the dense cache) → every populated sector dirties. Returns the vis set.
func _burst(ring: Node3D) -> PackedInt32Array:
	var vis: PackedInt32Array = ring.call("visible_fids")
	for f in vis:
		ring.call("_ensure_backstop_cached", int(f))
	return vis

## Per-sector facet counts for a fid set (via the ring's real `_sector_of`).
func _sector_counts(ring: Node3D, vis: PackedInt32Array) -> Dictionary:
	var d := {}
	for f in vis:
		var s := int(ring.call("_sector_of", int(f)))
		d[s] = int(d.get(s, 0)) + 1
	return d

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

# ---------------- G-STG-TRIG ----------------
## Trigger fires only on big bursts. A single dirtied sector (< TRIGGER facets) never stages; a full-cap burst does.
func _gate_trig() -> void:
	print("  --- G-STG-TRIG: single-sector dirt does NOT stage; the full-cap burst DOES ---")
	# (1) small: dirty ONE facet's signature ⇒ one sector dirty (~a few dozen facets < TRIGGER) ⇒ no stage.
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	var vis: PackedInt32Array = ring.call("visible_fids")
	_ok(vis.size() > CubeSphere.SHELL_STAGE_TRIGGER, "G-STG-TRIG: the orbit cap is a real burst (%d facets > TRIGGER %d)" % [vis.size(), CubeSphere.SHELL_STAGE_TRIGGER])
	ring.call("_ensure_backstop_cached", int(vis[0]))     # one facet → one sector dirty
	_dispatch(ring, true, true)
	_ok(not bool(ring.get("_stage_active")) and int(ring.get("_stage_deferred_n")) == 0,
		"G-STG-TRIG: one dirty sector (< TRIGGER) ⇒ no staged run (active=%s, deferred=%d)" % [str(ring.get("_stage_active")), int(ring.get("_stage_deferred_n"))])
	ring.free()
	# (2) big: the full-cap burst ⇒ staging engages, sectors deferred.
	var ring2 := _prep_ring(_R + ORBIT_D_ADD)
	_burst(ring2)
	_dispatch(ring2, true, true)
	_ok(bool(ring2.get("_stage_active")) and int(ring2.get("_stage_deferred_n")) > 0,
		"G-STG-TRIG: the full-cap burst stages (active=%s, deferred=%d > 0)" % [str(ring2.get("_stage_active")), int(ring2.get("_stage_deferred_n"))])
	ring2.free()

# ---------------- G-STG-BUDGET + G-STG-CONVERGE + G-STG-NOHOLE (one real staged drain) ----------------
func _gate_budget_converge_nohole() -> void:
	print("  --- G-STG-BUDGET / CONVERGE / NOHOLE: a real staged drain — per-cycle budget, converge-to-reference, no hole ---")
	# Reference (un-staged) run from the SAME burst state: one dispatch emits the WHOLE dirty set → the convergence oracle.
	var refr := _prep_ring(_R + ORBIT_D_ADD)
	var refvis := _burst(refr)
	_dispatch(refr, true, false)
	var ref_emit: Dictionary = _dict_keyset(refr.get("_emitted"))
	var counts := _sector_counts(refr, refvis)
	var max_sector := 0
	for s in counts.keys():
		max_sector = maxi(max_sector, int(counts[s]))
	var n_total := refvis.size()
	refr.free()
	var hard_bound: int = maxi(CubeSphere.SHELL_STAGE_FACETS, max_sector)

	# Staged run from the same start state.
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	_burst(ring)
	var budget_ok := true
	var min_slice := 1 << 30
	var max_slice := 0
	var hole_ok := true
	var resident_ok := true
	var cap := 2 * (n_total / maxi(1, CubeSphere.SHELL_STAGE_FACETS)) + 8
	var cycles := 0
	var drained := false
	while cycles < cap:
		ring.call("_dispatch_async_rebuild", true, true)
		var slice := int(ring.get("_stage_last_emit_facets"))
		var deferred := int(ring.get("_stage_deferred_n"))
		# per-cycle budget on the REAL path: the selected slice sits within max(BUDGET, largest single sector), ≥ 1.
		if slice < 1 or slice > hard_bound:
			budget_ok = false
		min_slice = mini(min_slice, slice)
		max_slice = maxi(max_slice, slice)
		# cross-check: the slice == the sum of member counts of the sectors actually left dirty this dispatch.
		var dirty: Dictionary = ring.get("_async_sector_dirty")
		var sum := 0
		for s in dirty.keys():
			sum += int(counts.get(int(s), 0))
		if sum != slice:
			budget_ok = false
		_drain_worker(ring)
		# NO-HOLE: the union of every sector's drawn shard (deferred included) still covers the reference emit.
		var emit_now: Dictionary = _dict_keyset(ring.get("_emitted"))
		if not _superset(emit_now, ref_emit):
			hole_ok = false
		# NO-HOLE: every built sector NOT dirtied this cycle keeps a non-null resident mesh at the current epoch.
		var mis: Array = ring.get("_sector_mi")
		var epoch := int(ring.get("_sector_epoch"))
		var built_epoch: PackedInt32Array = ring.get("_sector_built_epoch")
		for s in range(mis.size()):
			if dirty.has(s):
				continue
			if mis[s] != null and int(built_epoch[s]) == epoch:
				if (mis[s] as MeshInstance3D).mesh == null:
					resident_ok = false
		cycles += 1
		if deferred == 0:
			drained = true
			break
	_ok(drained, "G-STG-BUDGET: the staged run DRAINED (nothing deferred on the last cycle) in %d cycles" % cycles)
	_ok(cycles >= 2, "G-STG-BUDGET: the burst genuinely staged across multiple worker cycles (%d cycles)" % cycles)
	_ok(budget_ok, "G-STG-BUDGET: every staged slice ∈ [1, max(BUDGET=%d, largest-sector=%d)=%d] (min=%d max=%d)" % [CubeSphere.SHELL_STAGE_FACETS, max_sector, hard_bound, min_slice, max_slice])
	_ok(hole_ok, "G-STG-NOHOLE: the drawn union ⊇ the reference emit at EVERY intermediate cycle (sh_emit never drops)")
	_ok(resident_ok, "G-STG-NOHOLE: every non-dirty built sector kept a non-null resident mesh throughout (deferred sectors keep drawing)")
	# CONVERGE: the staged final shell is IDENTICAL to the un-staged reference.
	var final_emit: Dictionary = _dict_keyset(ring.get("_emitted"))
	_ok(_same_keyset(final_emit, ref_emit),
		"G-STG-CONVERGE: staged final emit == un-staged reference emit (%d == %d facets, key-equal)" % [final_emit.size(), ref_emit.size()])
	_ok(not bool(ring.get("_stage_active")), "G-STG-CONVERGE: the staged run released the hold at convergence (_stage_active false)")
	ring.free()

# ---------------- G-STG-MERGE ----------------
## Mid-run, inject NEW dirt on an ALREADY-EMITTED sector: it re-enters the dirty set, the run still drains, and no sector
## of the original deferred set is lost (each is eventually recorded at the current epoch).
func _gate_merge() -> void:
	print("  --- G-STG-MERGE: mid-run dirt on an emitted sector re-enters + drains; no deferred sector is ever lost ---")
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	var vis := _burst(ring)
	var n_total := vis.size()
	# cycle 1: capture the ORIGINAL deferred set (dirty-by-signature sectors minus the kept slice).
	ring.call("_dispatch_async_rebuild", true, true)
	var kept1: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	# every populated sector is dirty-by-signature this burst; the deferred set = all populated sectors − kept1.
	var all_pop := _sector_counts(ring, vis)
	var deferred_orig := {}
	for s in all_pop.keys():
		if not kept1.has(int(s)):
			deferred_orig[int(s)] = true
	_drain_worker(ring)
	_ok(deferred_orig.size() > 0, "G-STG-MERGE: cycle-1 deferred a non-empty original set (%d sectors)" % deferred_orig.size())
	# pick an ALREADY-EMITTED (kept, recorded) sector and inject new dirt by dropping a member's dense cache (bit-2 1→0).
	var merged_sector := -1
	var bpos: Dictionary = ring.get("_bpos_cache")
	for f in vis:
		var s := int(ring.call("_sector_of", int(f)))
		if kept1.has(s) and bpos.has(int(f)):
			bpos.erase(int(f))         # sig bit-2 flips back → sector re-dirties
			merged_sector = s
			break
	ring.set("_bpos_cache", bpos)
	_ok(merged_sector >= 0, "G-STG-MERGE: injected new dirt on an already-emitted sector (sector %d)" % merged_sector)
	# drain to convergence; the merged sector must re-enter the dirty set at least once.
	var cap := 2 * (n_total / maxi(1, CubeSphere.SHELL_STAGE_FACETS)) + 10
	var cycles := 0
	var merged_seen := false
	var drained := false
	while cycles < cap:
		ring.call("_dispatch_async_rebuild", true, true)
		var dirty: Dictionary = ring.get("_async_sector_dirty")
		if dirty.has(merged_sector):
			merged_seen = true
		var deferred := int(ring.get("_stage_deferred_n"))
		_drain_worker(ring)
		cycles += 1
		if deferred == 0:
			drained = true
			break
	_ok(merged_seen, "G-STG-MERGE: the re-dirtied emitted sector re-entered the dirty set during the drain")
	_ok(drained, "G-STG-MERGE: the run still drained to convergence with mid-run dirt merged (%d cycles)" % cycles)
	# no deferred sector lost: every originally-deferred sector is now recorded at the current epoch.
	var epoch := int(ring.get("_sector_epoch"))
	var built_epoch: PackedInt32Array = ring.get("_sector_built_epoch")
	var lost := 0
	for s in deferred_orig.keys():
		if int(built_epoch[int(s)]) != epoch:
			lost += 1
	_ok(lost == 0, "G-STG-MERGE: all %d originally-deferred sectors are recorded at the current epoch (0 lost)" % deferred_orig.size())
	ring.free()

# ---------------- G-STG-SUNKPIN (the stale-wedge regression, §4.2b) ----------------
## A burst caused ONLY by a sunk-state change. Drives the REAL `_sectors_compute_dirty(true)` + `_sectors_record_frozen`
## with sunkish sectors (FULL_COVER makes `_sector_sig_sunkish` reachable). After a PARTIAL (staged) record, the deferred
## sunkish sectors must STILL compute dirty via the per-sector record — this FAILS if the global `_sector_unsink_sig`
## compare were kept (proven inline: the global fingerprint now equals the current state, so a global test drops them).
func _gate_sunkpin() -> void:
	print("  --- G-STG-SUNKPIN: per-sector sunk record keeps deferred sunk-only sectors dirty (stale-wedge regression) ---")
	if not CubeSphere.FP_FARRING_FULL_COVER:
		_ok(false, "G-STG-SUNKPIN: FP_FARRING_FULL_COVER is OFF — sed it on so `_sector_sig_sunkish` can be true (see the RUN header)")
		return
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", _active)
	# Build a sunkish fid set spanning ≥ 2 sectors: take the active facet's face-quadrant plus a neighbour face's facets.
	var k := FA.K
	var fids := PackedInt32Array()
	# whole active face (6·? ) — enough to span multiple sectors on one face (SECTOR_SPLIT² per face).
	var face := int(_active / (k * k))
	for a in range(k):
		for b in range(k):
			fids.append((face * k + a) * k + b)
	# mark them sunkish: dense + coarse caches present (bits 1&2), and in the frozen backstop set.
	var backstop := {}
	for f in fids:
		ring.call("_ensure_cached", int(f))
		ring.call("_ensure_backstop_cached", int(f))
		backstop[int(f)] = true
	ring.set("_async_fids", fids)
	ring.set("_async_backstop", backstop)
	ring.set("_async_sectored", true)
	# size the per-sector sunk record (E4 sizes it under the compiled flag, which is off here — do it directly).
	var ns := int(ring.call("_sector_count"))
	var zeroes := []
	zeroes.resize(ns)
	ring.set("_sector_sunk_built", zeroes)
	# state A: build ALL sunkish sectors (record per-sector sunk = A). `_sectors_sunk_state()` reads the FROZEN dispatch
	# copies (`_async_unsink_col`/`_async_unsink_have_col`), so drive THOSE, not the live `_player_col_abs`.
	ring.set("_async_unsink_col", Vector3(_R, 0.0, 0.0))
	ring.set("_async_unsink_have_col", true)
	ring.call("_sectors_compute_dirty", true)
	var dirtyA: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	_ok(dirtyA.size() >= 2, "G-STG-SUNKPIN: the sunkish set spans ≥ 2 sectors (%d dirty)" % dirtyA.size())
	ring.set("_stage_active", true)                # so `_sectors_record_frozen` writes the per-sector sunk record
	ring.call("_sectors_record_frozen")            # records sig + _sector_sunk_built = A, epoch-current, for all
	# state B: change ONLY the sunk state (unsink column) — a sunk-only burst.
	ring.set("_async_unsink_col", Vector3(_R + 40.0, 5.0, 0.0))
	ring.call("_sectors_compute_dirty", true)
	var dirtyB: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	_ok(dirtyB.size() == dirtyA.size(), "G-STG-SUNKPIN: the sunk-only change re-dirties every sunkish sector (%d)" % dirtyB.size())
	# STAGE: keep ONLY one sector, defer the rest; record the kept one against state B.
	var kept := int(dirtyB.keys()[0])
	var deferred_set := {}
	for s in dirtyB.keys():
		if int(s) != kept:
			deferred_set[int(s)] = true
	ring.set("_async_sector_dirty", {kept: true})
	ring.call("_sectors_record_frozen")            # kept sector: _sector_sunk_built = B; GLOBAL _sector_unsink_sig = B
	# recompute (state B still live == the hold): kept clean, deferred STILL dirty via the per-sector record.
	ring.call("_sectors_compute_dirty", true)
	var dirtyC: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	var deferred_still_dirty := true
	for s in deferred_set.keys():
		if not dirtyC.has(int(s)):
			deferred_still_dirty = false
	_ok(deferred_still_dirty and not dirtyC.has(kept),
		"G-STG-SUNKPIN: after the partial record, deferred sunk sectors STAY dirty (%d) and the recorded one is clean" % deferred_set.size())
	# REGRESSION proof: the GLOBAL fingerprint now equals the live sunk-state, so a global compare would drop them.
	var global_sig: Array = ring.get("_sector_unsink_sig")
	var cur_sunk: Array = ring.call("_sectors_sunk_state")
	_ok(global_sig == cur_sunk,
		"G-STG-SUNKPIN (regression): the GLOBAL _sector_unsink_sig == current sunk-state ⇒ a global compare WOULD drop the deferred wedge — the per-sector record is load-bearing")
	ring.free()

# ---------------- G-STG-HOLD ----------------
## During the run the live column/applied radius are mutated between cycles; every staged dispatch must freeze the SAME
## stage-hold values, and the first post-run dispatch picks the live values back up.
func _gate_hold() -> void:
	print("  --- G-STG-HOLD: staged dispatches freeze the stage-start inputs; the post-run dispatch takes the live values ---")
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	ring.set("_player_col_abs", Vector3(_R, 0.0, 0.0))
	ring.set("_unsink_have_col", true)
	ring.set("_applied_r", 10.0)
	var vis := _burst(ring)
	var n_total := vis.size()
	# cycle 1 starts the run and captures the hold.
	ring.call("_dispatch_async_rebuild", true, true)
	_drain_worker(ring)
	_ok(bool(ring.get("_stage_active")), "G-STG-HOLD: the run is active after cycle 1")
	var hold: Array = ring.get("_stage_hold")
	var hold_col: Vector3 = hold[0]
	var hold_r: float = hold[2]
	# mutate the LIVE inputs mid-run.
	ring.set("_player_col_abs", Vector3(_R + 999.0, 111.0, 222.0))
	ring.set("_applied_r", 77.0)
	# subsequent staged dispatches must STILL freeze the stage-start hold, not the mutated live values.
	var froze_hold := true
	var cap := 2 * (n_total / maxi(1, CubeSphere.SHELL_STAGE_FACETS)) + 10
	var cycles := 0
	while cycles < cap and bool(ring.get("_stage_active")):
		ring.call("_dispatch_async_rebuild", true, true)
		if (ring.get("_async_unsink_col") as Vector3) != hold_col or absf(float(ring.get("_async_applied_r")) - hold_r) > 0.001:
			froze_hold = false
		_drain_worker(ring)
		cycles += 1
	_ok(froze_hold, "G-STG-HOLD: every staged dispatch froze the stage-start unsink-col/applied-r (hold), ignoring the live mutation")
	_ok(not bool(ring.get("_stage_active")), "G-STG-HOLD: the run drained")
	# post-run dispatch: no staging active ⇒ the live (mutated) values are frozen.
	ring.call("_dispatch_async_rebuild", true, true)
	_drain_worker(ring)
	_ok((ring.get("_async_unsink_col") as Vector3) == Vector3(_R + 999.0, 111.0, 222.0),
		"G-STG-HOLD: the first post-run dispatch picked up the LIVE unsink column (hold released)")
	ring.free()

# ---------------- G-STG-FAILSAFE ----------------
## Injecting a stale stage-start clock past SHELL_STAGE_MAX_MS ⇒ the next dispatch emits the full remainder unbudgeted
## and closes the run.
func _gate_failsafe() -> void:
	print("  --- G-STG-FAILSAFE: past SHELL_STAGE_MAX_MS the remainder emits unbudgeted + the run closes ---")
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	_burst(ring)
	# start a run.
	ring.call("_dispatch_async_rebuild", true, true)
	_drain_worker(ring)
	_ok(bool(ring.get("_stage_active")) and int(ring.get("_stage_deferred_n")) > 0, "G-STG-FAILSAFE: a staged run is in progress")
	# the FULL remaining dirty set the next un-failsafed dispatch WOULD compute (oracle).
	ring.call("_sectors_compute_dirty", true)
	var full_remaining := int((ring.get("_async_sector_dirty") as Dictionary).size())
	# inject a stale clock → force the failsafe on the next dispatch.
	ring.set("_stage_start_ms", Time.get_ticks_msec() - CubeSphere.SHELL_STAGE_MAX_MS - 1)
	ring.call("_dispatch_async_rebuild", true, true)
	var emitted_dirty := int((ring.get("_async_sector_dirty") as Dictionary).size())
	_ok(emitted_dirty == full_remaining and full_remaining > 0,
		"G-STG-FAILSAFE: the dispatch emitted the FULL remaining dirty set unbudgeted (%d sectors, nothing deferred)" % emitted_dirty)
	_ok(int(ring.get("_stage_deferred_n")) == 0 and not bool(ring.get("_stage_active")),
		"G-STG-FAILSAFE: the run closed (deferred=0, _stage_active false)")
	_drain_worker(ring)
	ring.free()

# ---------------- G-STG-BYTEOFF ----------------
## stage_on=false: the burst emits in ONE dispatch (whole dirty set, no filtering), stage state never leaves zero, and
## the dirty set is element-equal to the flag-ON pre-filter set.
func _gate_byteoff() -> void:
	print("  --- G-STG-BYTEOFF: stage_on=false ⇒ one-dispatch whole-burst emit; stage state stays zero ---")
	# (a) the REAL byte-off dispatch: the whole burst emits in ONE un-staged dispatch, stage state never leaves zero.
	var refr := _prep_ring(_R + ORBIT_D_ADD)
	var refvis := _burst(refr)
	_dispatch(refr, true, false)
	var ref_emit: Dictionary = _dict_keyset(refr.get("_emitted"))
	_ok(not bool(refr.get("_stage_active")) and int(refr.get("_stage_deferred_n")) == 0 and int(refr.get("_stage_last_emit_facets")) == 0,
		"G-STG-BYTEOFF: stage_on=false leaves _stage_* at zero (active=%s deferred=%d emit=%d)" % [str(refr.get("_stage_active")), int(refr.get("_stage_deferred_n")), int(refr.get("_stage_last_emit_facets"))])
	var visset := _int_set(refvis)
	_ok(_superset(ref_emit, visset) and ref_emit.size() >= visset.size(),
		"G-STG-BYTEOFF: the whole burst emitted in ONE dispatch (emit %d ⊇ visible %d — no deferral)" % [ref_emit.size(), visset.size()])
	refr.free()
	# (b) element-equality: on a burst state (no swap between), the stage_on=true PRE-FILTER dirty set == the stage_on=false
	# dirty set (orbit ⇒ no sunkish delta). Computed directly without dispatching a worker, so nothing records in between.
	var ring := _prep_ring(_R + ORBIT_D_ADD)
	_burst(ring)
	ring.set("_async_fids", ring.call("visible_fids"))
	ring.set("_async_sectored", true)
	ring.call("_sectors_compute_dirty", true)
	var onset: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	ring.call("_sectors_compute_dirty", false)
	var offset: Dictionary = _dict_keyset(ring.get("_async_sector_dirty"))
	_ok(onset.size() > 0 and _same_keyset(offset, onset),
		"G-STG-BYTEOFF: stage_on=false dirty set == stage_on=true pre-filter set (%d == %d, element-equal)" % [offset.size(), onset.size()])
	ring.free()
