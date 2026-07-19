extends SceneTree
## COSMOS FS2 (docs/COSMOS-FACET-SEAMS-DESIGN.md §3 / §6) — the FP_RADIAL_DATUM gate: the seam-step KILL.
##
## FS0 pinned the placement-datum cliff at 5.30 blocks (adjacent facets place the same surface g at different
## altitudes because each counts g up from its OWN mean plane). FS2 adds the per-column datum shift S so the
## placed surface sits at the RADIAL altitude R + g — a pure function of d̂ — collapsing the cliff to the ±1
## quantization the terrain has everywhere. This gate measures the step through the REAL placement path
## (FacetAtlas.lattice_to_world64 at g + datum_shift) and BRANCHES on the flag:
##
##   flag ON  — G-DATUM-SEAM   adjacent facets' surface altitude at matched d̂ agree ≤ 1.15 blocks over every seam
##                             (the direct regression for the 8-block-cliff complaint; was 5.30).
##              G-DATUM-RADIAL every sampled column's surface altitude equals R + g to ≤ 0.65 (One-Surface Law).
##              G-DATUM-OCEAN  a sea-level column (g ≤ SEA_LEVEL) rides S too — its sea surface altitude agrees ≤1.15.
##   flag OFF — G-DATUM-OFF    S ≡ 0 ⇒ the FS0 cliff (5.30) returns, proving the flag is what closes it (byte-off).
##
## The near-field geometry is headless-proven here; the "cliffs gone on foot / from flight" look is live-only.
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_RADIAL_DATUM := false/const FP_RADIAL_DATUM := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_facet_datum.gd
##   then REVERT. RUN (flag OFF complement): sed FACETED only. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const K := 24
const _TS := [0.0, 0.25, 0.5, 0.75, 1.0]

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# ------- f64 helpers (shared with the FS0 pin; kept local so this gate is a standalone oracle) -------
func _vdir(face: int, i: int, j: int) -> Array:
	var d := CosmosFacet.vertex_dir(face, i, j, K)
	return [d.x, d.y, d.z]
func _norm(a: Array) -> Array:
	var l := sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
	return [a[0] / l, a[1] / l, a[2] / l]
func _lerp3(a: Array, b: Array, t: float) -> Array:
	return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
func _rlen(w: Array) -> float:
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])

func _neigh(face: int, a: int, b: int, slot: int) -> Array:
	var ni := a; var nj := b
	match slot:
		0: ni = a + 1
		1: ni = a - 1
		2: nj = b + 1
		_: nj = b - 1
	var fold: Dictionary = CubeSphere.fold_cell(face, ni, nj, K)
	return [int(fold["face"]), int(fold["i"]), int(fold["j"])]
func _edge_ij(a: int, b: int, slot: int) -> Array:
	match slot:
		0: return [a + 1, b, a + 1, b + 1]
		1: return [a, b, a, b + 1]
		2: return [a, b + 1, a + 1, b + 1]
		_: return [a, b, a + 1, b]

## The REAL placed surface altitude of the column nearest edge-direction `dm` on facet `fid`, at surface height
## `g` — |lattice_to_world64(fid, x, g + S(fid,x,z), z)|. Uses the actual atlas placement + the datum shift.
func _placed_alt(fid: int, dm: Array, g: int) -> float:
	var q := [dm[0] * FA.R_BLOCKS, dm[1] * FA.R_BLOCKS, dm[2] * FA.R_BLOCKS]
	var lat := FA.world_to_lattice64(fid, q[0], q[1], q[2])
	var cx := int(round(lat[0])); var cz := int(round(lat[2]))
	var s := FA.datum_shift(fid, cx, cz)
	var w := FA.lattice_to_world64(fid, lat[0], float(g + s), lat[2])
	return _rlen(w)

func _initialize() -> void:
	print("=== verify_facet_datum (FS2: the seam-step kill) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	print("  atlas: k=%d, R=%.0f, FP_RADIAL_DATUM=%s, DATUM_SHIFT_MAX=%d" % [
		FA.K, FA.R_BLOCKS, str(CubeSphere.FP_RADIAL_DATUM), FA.DATUM_SHIFT_MAX])

	# ---- seam step through the real placement path (same g both sides ⇒ isolates the datum step) ----
	var max_step := 0.0
	var max_ocean := 0.0
	var w_fidA := -1; var w_slot := -1
	for face in range(6):
		for a in range(K):
			for b in range(K):
				var fidA := (face * K + a) * K + b
				for slot in range(4):
					var fidB := FA.seam_neighbour(fidA, slot)
					var ev := _edge_ij(a, b, slot)
					var d0 := _vdir(face, ev[0], ev[1]); var d1 := _vdir(face, ev[2], ev[3])
					for t in _TS:
						var dm := _norm(_lerp3(d0, d1, t))
						var g := int(TerrainConfig.profile_at_dir(dm[0], dm[1], dm[2], FA.R_BLOCKS).x)
						var step: float = absf(_placed_alt(fidA, dm, g) - _placed_alt(fidB, dm, g))
						if step > max_step:
							max_step = step; w_fidA = fidA; w_slot = slot
						# G-DATUM-OCEAN: a sea-level/underwater column rides S too (its sea surface stays continuous)
						if g <= TerrainConfig.SEA_LEVEL:
							var so: float = absf(_placed_alt(fidA, dm, TerrainConfig.SEA_LEVEL) - _placed_alt(fidB, dm, TerrainConfig.SEA_LEVEL))
							max_ocean = maxf(max_ocean, so)

	if CubeSphere.FP_RADIAL_DATUM:
		print("  G-DATUM-SEAM: worst placed-surface step over all 13824 seams = %.4f blocks (worst A=%d slot=%d)" % [max_step, w_fidA, w_slot])
		_ok(max_step <= 1.15, "seam step %.4f > 1.15 — the datum shift did not collapse the cliff" % max_step)
		print("  G-DATUM-OCEAN: worst sea-surface step over seams touching ocean = %.4f blocks" % max_ocean)
		_ok(max_ocean <= 1.15, "ocean seam step %.4f > 1.15 — the sea does not ride S" % max_ocean)
		_gate_radial()
		_gate_wired()
	else:
		print("  G-DATUM-OFF: worst placed-surface step (flag off, S=0) = %.4f blocks" % max_step)
		_ok(absf(max_step - 5.30) <= 0.20, "flag-off step %.4f != ~5.30 — the FS0 cliff should return with S=0" % max_step)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## G-DATUM-RADIAL: the placed surface altitude equals R + g everywhere (One-Surface Law) — the property that
## makes it seam-continuous. Sampled over a spread of facets/columns (centre + off-centre cells).
func _gate_radial() -> void:
	var worst := 0.0
	for face in range(6):
		for a in range(0, K, 3):
			for b in range(0, K, 3):
				var fid := (face * K + a) * K + b
				var cc := FA.centre_cell(fid)
				for dxy in [[0, 0], [40, 0], [0, 40], [-40, 30]]:
					var cx: int = cc.x + int(dxy[0]); var cz: int = cc.y + int(dxy[1])
					var g := int(TerrainConfig.facet_profile(fid, cx, cz).x)
					var s := FA.datum_shift(fid, cx, cz)
					var w := FA.lattice_to_world64(fid, float(cx), float(g + s), float(cz))
					worst = maxf(worst, absf(_rlen(w) - (FA.R_BLOCKS + float(g))))
	print("  G-DATUM-RADIAL: worst |placed_alt − (R+g)| over sampled columns = %.4f blocks" % worst)
	_ok(worst <= 0.65, "placed surface is not radial: |alt − (R+g)| %.4f > 0.65" % worst)

## G-DATUM-WIRED: the actual worldgen re-index is live — the surface funnel (height_at) returns g + S and the
## analytic cell path (generated_cell) places the surface at lattice g + S with the raised band g+1..g+S filled.
## This proves the GDScript wiring (analytic + funnel) does the shift, not just the datum_shift helper geometry.
func _gate_wired() -> void:
	var fid := FA.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var cc := FA.centre_cell(fid)
	var checked := 0
	var ok_h := true; var ok_solid := true; var ok_raise := true
	for dxy in [[0, 0], [10, 10], [-10, 5], [5, -10], [20, -6], [-14, 12]]:
		var x: int = cc.x + int(dxy[0]); var z: int = cc.y + int(dxy[1])
		var g := int(TerrainConfig.facet_profile(fid, x, z).x)
		var s := FA.datum_shift(fid, x, z)
		if g <= TerrainConfig.SEA_LEVEL or s <= 0:
			continue                                    # want a LAND column that actually shifts
		checked += 1
		if TerrainConfig.height_at(x, z) != g + s:
			ok_h = false
		if CellCodec.mat(TerrainConfig.generated_cell(x, g + s, z)) == 0:
			ok_solid = false                            # the surface must be SOLID at lattice g+S
		if CellCodec.mat(TerrainConfig.generated_cell(x, g + 1, z)) == 0:
			ok_raise = false                            # the raised band g+1..g+S must be filled (was air pre-shift)
	print("  G-DATUM-WIRED: %d land columns checked; height_at==g+S:%s surface-solid@g+S:%s raised-band-filled:%s" % [
		checked, str(ok_h), str(ok_solid), str(ok_raise)])
	_ok(checked >= 2, "no land column with S>0 sampled — cannot verify the wiring")
	_ok(ok_h, "height_at does not return g + S (surface funnel not wired)")
	_ok(ok_solid, "generated_cell is not solid at the placed surface g + S (analytic exit not wired)")
	_ok(ok_raise, "the raised band g+1..g+S is not filled (the datum re-index did not run)")
