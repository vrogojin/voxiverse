extends SceneTree
## COSMOS-PERF UNATTENDED R5 gate — G-EDIT-FID-INDEX (flag CubeSphere.FP_EDIT_FID_INDEX).
##
## W4: `_rebuild_window_indices` (run on EVERY facet crossing) and `_translate_active` rescan the WHOLE `_edits`
## overlay — O(all edits) — and filter to the active facet. Snow authors up to ~200 k `_edits` cells over a session,
## so the crossing scan grows unbounded and crossings get PROGRESSIVELY SLOWER the longer you play (the measured
## 1.7–19 ms crossing_ms was a young session). R5 maintains a per-facet index (`_edits_by_fid`) in the single
## write/erase choke points, so the crossing rebuild touches ONLY the incoming facet's edits — O(active-fid),
## INDEPENDENT of the total edit count.
##
## THE RIGHT CONDITION (per the doc): seed ~200 k synthetic snow edits BEFORE the crossing rebuild — a settled young
## session would not exercise W4. The gate measures the INDEXED-EDITS-TOUCHED count (rebuild_scanned_last), NOT
## wall-clock (unreliable on web), and asserts it is bounded + independent of the 200 k total. It also proves the
## per-fid index returns the SAME edit set (and the SAME rebuilt `_edit_columns`/`_placed_top`) the full scan would.
##
## RUN (needs FACETED = true; sed-toggle FP_EDIT_FID_INDEX = true for the O(window) asserts):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_EDIT_FID_INDEX := false/const FP_EDIT_FID_INDEX := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_edit_fid_index.gd
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const WM := preload("res://src/world/world_manager.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Seed `count` DISTINCT overlay edits on facet `fid` (some placed >0, some dug air 0). Returns the number seeded.
func _seed_facet(w, fid: int, count: int, ybase: int) -> int:
	TC.set_active_facet(fid)
	for i in range(count):
		var x := i % 180
		var z := (i / 180) % 180
		var y := ybase + (i / 32400)                 # bump y after the 180×180 plane fills → stays distinct
		var val := 0 if (i % 7 == 0) else (3 + (i % 5))   # ~1/7 dug air, rest placed block ids
		w.seed_edit_for_test(Vector3i(x, y, z), val)
	return count

func _initialize() -> void:
	print("=== verify_edit_fid_index (COSMOS-PERF UNATTENDED R5: G-EDIT-FID-INDEX) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	var on: bool = CubeSphere.FP_EDIT_FID_INDEX
	print("  FP_EDIT_FID_INDEX=%s" % str(on))

	var w = WM.new()   # no add_child: _write_cell/_rebuild_window_indices need no tree state under FACETED (_chart null)
	var A := FA.spawn_facet()
	var nbrs: Array = []
	for slot in range(4):
		var nb := FA.seam_neighbour(A, slot)
		if nb != A and nb >= 0 and not nbrs.has(nb):
			nbrs.append(nb)
	_ok(nbrs.size() >= 2, "setup: found ≥2 distinct neighbour facets of A=%d (%s)" % [A, str(nbrs)])

	# --- Seed the RIGHT condition: a SMALL active-facet window (~400) + a LARGE cross-session snow trail (~200 k). ---
	var N_A := 400
	_seed_facet(w, A, N_A, 64)
	var per_nbr := 50_000
	var seeded_other := 0
	for nb in nbrs:
		seeded_other += _seed_facet(w, nb, per_nbr, 96)
	TC.set_active_facet(A)
	var total := w.edit_count()
	print("  seeded: A(active)=%d  others=%d (%d facets)  TOTAL _edits=%d" % [N_A, seeded_other, nbrs.size(), total])
	_ok(total >= 150_000, "setup: seeded a session-scale overlay (≥150 k edits: %d)" % total)

	if not on:
		# BYTE-IDENTICAL baseline: with the flag OFF the index is never built; the rebuild full-scans ALL edits.
		w._rebuild_window_indices()
		_ok(w.edits_for_fid(A).is_empty(), "OFF: the per-fid index is never populated (byte-identical scan path)")
		_ok(w.rebuild_scanned_last() == total, "OFF: the rebuild scans ALL %d edits (O(all edits) — the W4 cost)" % total)
		print("  NOTE: sed FP_EDIT_FID_INDEX=true (with FACETED=true) to exercise the O(window) + correctness asserts.")
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	# ---- O(WINDOW) PROOF: the crossing rebuild touches only the ACTIVE facet's edits, independent of the total. ----
	w._rebuild_window_indices()
	var scanned1 := w.rebuild_scanned_last()
	print("  rebuild#1 (active=A): scanned=%d  vs total=%d  index[A].size=%d" % [scanned1, total, w.edits_for_fid(A).size()])
	_ok(scanned1 == N_A, "O(window): the rebuild touched EXACTLY the active facet's %d edits (scanned=%d)" % [N_A, scanned1])
	_ok(scanned1 < total / 10, "O(window): scanned (%d) ≪ total (%d) — NOT O(all edits)" % [scanned1, total])

	# INDEPENDENCE: grow the cross-session trail by another ~100 k on the neighbours; the active-window scan is unmoved.
	var extra := 0
	for nb in nbrs:
		extra += _seed_facet(w, nb, 25_000, 200)   # distinct y-band (200) → new distinct keys, all on non-active facets
	TC.set_active_facet(A)
	var total2 := w.edit_count()
	w._rebuild_window_indices()
	var scanned2 := w.rebuild_scanned_last()
	print("  rebuild#2 after +%d more (total now %d): scanned=%d" % [extra, total2, scanned2])
	_ok(total2 > total + 50_000, "independence setup: total grew by ≥50 k (%d → %d)" % [total, total2])
	_ok(scanned2 == scanned1, "INDEPENDENCE: the crossing scan is UNCHANGED (%d) as the total edit count grew (%d → %d)" % [scanned2, total, total2])

	# ---- CORRECTNESS: the per-fid index == the full scan filtered to A (same edit SET), and the rebuilt window ----
	# ---- PERF indices (`_edit_columns`/`_placed_top`) are byte-identical to a manual full-scan reference.       ----
	var ref_keys := {}
	var ref_cols := {}
	var ref_tops := {}
	for k in w.all_edit_keys():
		if FA.edit_key_fid(k) != A:
			continue
		ref_keys[k] = true
		var cell: Vector3i = FA.edit_key_unpack(k)[1]
		var col := Vector2i(cell.x, cell.z)
		ref_cols[col] = true
		# mirror _rebuild_window_indices: a PLACED (value > 0) cell raises the column's high-water mark
		var val := int(w.all_edit_value(k))
		if val > 0:
			var prev: int = ref_tops.get(col, -0x40000000)
			if cell.y > prev:
				ref_tops[col] = cell.y

	var idx := w.edits_for_fid(A)
	var same_set := (idx.size() == ref_keys.size())
	if same_set:
		for k in ref_keys.keys():
			if not idx.has(k):
				same_set = false
				break
	_ok(same_set, "CORRECTNESS: per-fid index key set == full-scan-filtered set (size idx=%d ref=%d)" % [idx.size(), ref_keys.size()])

	var got_cols := w.debug_edit_columns()
	var cols_match := (got_cols.size() == ref_cols.size())
	if cols_match:
		for c in ref_cols.keys():
			if not got_cols.has(c):
				cols_match = false
				break
	_ok(cols_match, "CORRECTNESS: rebuilt _edit_columns == full-scan reference (size got=%d ref=%d)" % [got_cols.size(), ref_cols.size()])

	var got_tops := w.debug_placed_top()
	var tops_match := (got_tops.size() == ref_tops.size())
	if tops_match:
		for c in ref_tops.keys():
			if int(got_tops.get(c, -0x40000000)) != int(ref_tops[c]):
				tops_match = false
				break
	_ok(tops_match, "CORRECTNESS: rebuilt _placed_top == full-scan reference (size got=%d ref=%d)" % [got_tops.size(), ref_tops.size()])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
