extends SceneTree
## COSMOS DE-ORBIT SLICE SMOOTHING P3 gate (docs/COSMOS-DEORBIT-SLICE-SMOOTHING-DESIGN.md §7, FP_SV2_SHELL_YIELD) —
## proves the smooth-V2 shell-slice yield: while a staged shell run is landing, `FacetSmoothV2.step(..., shell_yield=true)`
## defers ONLY the main-thread commit (reap/evict/dispatch still run); `_dirty` accumulates and the first `shell_yield=false`
## step folds the whole backlog into ONE commit (the FP_SMOOTH_V2_PACE accumulation law — deferral is lossless).
##
## FLAG-INDEPENDENT (drives `step()`'s `shell_yield` param directly, the codebase forcing-param convention). The flag's
## default-false byte-off is that the ONLY call site passes `false` (FLAT 6042/0 covers it). Mirrors verify_fast_load's
## isolate-the-commit-path pattern (`_want`/`_want_order` empty ⇒ no dispatch, the commit path alone).
##
## RUN (needs FACETED for FacetSmoothV2.setup_instance's atlas/cpp-gen wiring):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_sv2_yield.gd
##   then REVERT the sed + re-import. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _fresh_sv(ring: Node3D) -> FacetSmoothV2:
	var sv := FacetSmoothV2.new()
	sv.setup_instance(ring, FA.spawn_facet())
	sv._want = {}          # isolate the commit path — no dispatch either way
	sv._want_order = []
	return sv

func _initialize() -> void:
	print("=== verify_sv2_yield (COSMOS DE-ORBIT SLICE SMOOTHING P3 — FP_SV2_SHELL_YIELD) ===")
	FA.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	var ring := Node3D.new()
	get_root().add_child(ring)

	# --- Y1: shell_yield=true defers the commit; `_dirty` is retained (the reap/evict/dispatch already ran above it).
	var sv := _fresh_sv(ring)
	sv._dirty = true
	sv.step(true, true, true)                # settled, credit-ok, shell_yield=TRUE
	_ok(sv.commit_count() == 0 and sv._dirty, "Y1 shell_yield=true: commit DEFERRED, `_dirty` retained (count=%d)" % sv.commit_count())

	# --- Y2: a second yielding step still defers — the backlog accumulates, bounded by the staged run (no commit storm).
	sv._dirty = true
	sv.step(true, true, true)
	_ok(sv.commit_count() == 0 and sv._dirty, "Y2 shell_yield=true again: still deferred, backlog accumulates (count=%d)" % sv.commit_count())

	# --- Y3: the first shell_yield=false step lands ONE commit that folds the whole accumulated backlog (lossless).
	sv.step(true, true, false)               # shell_yield=FALSE ⇒ the PACE law commits the folded dirty set
	_ok(sv.commit_count() == 1 and not sv._dirty, "Y3 shell_yield=false: the folded backlog commits ONCE (count=%d, dirty cleared)" % sv.commit_count())

	# --- Y4: byte-off — the shipped 2-arg call (shell_yield defaults false) commits on the reap exactly as before.
	var sv2 := _fresh_sv(ring)
	sv2._dirty = true
	sv2.step(true, true)                     # no shell_yield arg ⇒ default false ⇒ shipped commit-on-reap
	_ok(sv2.commit_count() == 1, "Y4 byte-off: the 2-arg step (shell_yield default false) commits verbatim (count=%d)" % sv2.commit_count())

	# FacetSmoothV2 is RefCounted (auto-freed when the locals drop); `_mi` children are freed with `ring`.
	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
