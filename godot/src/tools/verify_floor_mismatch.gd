extends SceneTree
## COSMOS FS2′ collision-floor gate — the analytic floor must equal the RENDERED / generated terrain top on
## every faceted column (docs/COSMOS-FACET-SEAMS-V2.md §2). Root cause it kills: WorldManager.surface_y omitted
## the per-column datum lift s(fid,x,z) that floor_under / blocked / ceiling_scan / the DDA AND the near mesh all
## apply, so surface_y reported the surface up to the facet-centre sagitta (~5-7 blocks @ R=6371) BELOW the
## visible ground — set_alt/spawn/teleport sank the player into solid terrain.
##
## THE rendered near-mesh top is effective_height(x,z)+1 + s (verify_facet_seams.gd G-D2-SHAPE, line ~336). The
## gate asserts surface_y == that over a sweep (spawn facet + off-spawn facets + both sides of seams), that the
## repro-class facet-centre columns really had a ≥5-block would-be mismatch that the fix now supplies, and that
## surface_y agrees with the independent floor_under scan the player actually stands on. Falsify by reverting
## surface_y to `effective_height+1` (drop the lift) ⇒ G-FLOOR-RENDER / G-FLOOR-REPRO fail.
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_DATUM_BAKE := false/const FP_DATUM_BAKE := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_floor_mismatch.gd
##   then REVERT. Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const REPRO := Vector3(5133.8, -2825.03, -2454.38)   # measured live sink position (owner facet 101)
const EPS := 0.001

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# The RENDER / One-Surface top of column (xi,zi) on the ACTIVE facet: effective_height+1 + datum_lift.
# (verify_facet_seams.gd:336 uses exactly effective_height+1 + the C++ per-vertex lift, which datum_lift mirrors.)
func _render_top(w: WorldManager, fid: int, xi: int, zi: int) -> float:
	return float(w.effective_height(xi, zi) + 1) + FA.datum_lift(fid, float(xi) + 0.5, float(zi) + 0.5)

func _initialize() -> void:
	print("=== verify_floor_mismatch (FS2′ collision-floor == render) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true (and FP_DATUM_BAKE = true) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	print("  atlas: k=%d R=%d spawn=%d | FP_RADIAL_DATUM=%s FP_DATUM_BAKE=%s" % [
		FA.K, int(FA.R_BLOCKS), FA.spawn_facet(), str(CubeSphere.FP_RADIAL_DATUM), str(CubeSphere.FP_DATUM_BAKE)])

	var w: WorldManager = WorldManager.new()
	w.name = "FloorMismatchWM"
	get_root().add_child(w)

	_gate_render_equals_surface(w)
	_gate_repro_class(w)
	_gate_floor_under_agrees(w)
	_gate_seam_columns(w)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## G-FLOOR-RENDER — surface_y(x,z) == the rendered near-mesh top (effective_height+1 + s) at EVERY sampled column,
## on the spawn facet and several off-spawn facets, centre → toward the corners (where s ranges from its sagitta
## max to ~0). Pre-fix (surface_y = effective_height+1) this fails wherever s > EPS.
func _gate_render_equals_surface(w: WorldManager) -> void:
	var worst := 0.0
	var checked := 0
	var facets: Array = [FA.spawn_facet(), 0, 101, 500, 1200, 2000, 3000]
	for fid in facets:
		if fid < 0 or fid >= FA.facet_count():
			continue
		TC.set_active_facet(fid)
		var cc := FA.centre_cell(fid)
		for d in [[0, 0], [8, 0], [16, 0], [23, 0], [0, 23], [23, 23], [-23, 23], [-16, -16], [40, 8]]:
			var xi: int = cc.x + int(d[0])
			var zi: int = cc.y + int(d[1])
			var sy := w.surface_y(float(xi) + 0.5, float(zi) + 0.5)
			var rt := _render_top(w, fid, xi, zi)
			var err: float = absf(sy - rt)
			if err > worst:
				worst = err
			checked += 1
			if err > EPS:
				print("    MISMATCH fid=%d (%d,%d) surface_y=%.3f render_top=%.3f d=%.3f" % [fid, xi, zi, sy, rt, err])
	print("  G-FLOOR-RENDER: %d columns; worst |surface_y - render_top| = %.4f" % [checked, worst])
	_ok(checked >= 40, "too few columns sampled (%d)" % checked)
	_ok(worst <= EPS, "surface_y diverges from the rendered top by %.4f (> %.4f) — the datum lift is missing" % [worst, EPS])

## G-FLOOR-REPRO — the repro CLASS: at facet-centre columns (max sagitta) the datum lift s is a REAL ≥5-block
## displacement, and the fix supplies EXACTLY it: surface_y − (effective_height+1) == s. Also reconstructs the
## measured live position (facet 101, s≈5-7) whose pre-fix surface_y was ≥5 blocks below the visible ground.
func _gate_repro_class(w: WorldManager) -> void:
	# (a) facet-centre columns across a spread of facets: s must reach ≥5 somewhere, and the fix restores it.
	var max_s := 0.0
	var worst_supply := 0.0
	for fid in [FA.spawn_facet(), 0, 101, 800, 1700, 2600]:
		if fid < 0 or fid >= FA.facet_count():
			continue
		TC.set_active_facet(fid)
		var cc := FA.centre_cell(fid)
		var s := FA.datum_lift(fid, float(cc.x) + 0.5, float(cc.y) + 0.5)
		max_s = maxf(max_s, s)
		var sy := w.surface_y(float(cc.x) + 0.5, float(cc.y) + 0.5)
		var pre := float(w.effective_height(cc.x, cc.y) + 1)     # what surface_y returned BEFORE the fix
		worst_supply = maxf(worst_supply, absf((sy - pre) - s))  # the fix must supply exactly s
	print("  G-FLOOR-REPRO: max facet-centre datum lift s = %.3f blocks; worst |(surface_y - preFix) - s| = %.4f" % [max_s, worst_supply])
	_ok(max_s >= 5.0, "no facet-centre column reached a >=5-block datum lift (max %.3f) — cannot exercise the repro class" % max_s)
	_ok(worst_supply <= EPS, "the fix does not supply exactly the missing lift s (residual %.4f)" % worst_supply)

	# (b) the exact measured live position → its owner facet + column; surface_y must equal the render there.
	var base := FA.fid_base(0)
	var owner := -1
	var ox := 0
	var oz := 0
	for fid in range(base, base + FA.body_facet_count(0)):
		var l: Array = FA.world_to_lattice64(fid, REPRO.x, REPRO.y, REPRO.z)
		var lx := int(floor(l[0]))
		var lz := int(floor(l[2]))
		if FA.in_polygon(fid, lx, lz, 0.5):
			owner = fid
			ox = lx
			oz = lz
			break
	_ok(owner >= 0, "could not resolve the repro world position to an owner facet")
	if owner >= 0:
		TC.set_active_facet(owner)
		var sy := w.surface_y(float(ox) + 0.5, float(oz) + 0.5)
		var rt := _render_top(w, owner, ox, oz)
		var pre := float(w.effective_height(ox, oz) + 1)
		var s := FA.datum_lift(owner, float(ox) + 0.5, float(oz) + 0.5)
		print("  G-FLOOR-REPRO-POS: owner facet=%d col=(%d,%d) s=%.3f | preFix surface_y=%.3f  fixed surface_y=%.3f  render=%.3f" % [
			owner, ox, oz, s, pre, sy, rt])
		_ok(absf(sy - rt) <= EPS, "repro column: fixed surface_y %.3f != render top %.3f" % [sy, rt])
		_ok(absf(pre - rt) >= 0.5, "repro column: pre-fix surface_y was NOT below the render (no bug to fix here) — pick a lifted column")

## G-FLOOR-UNDER — surface_y sits on the SAME lifted datum as the INDEPENDENT floor_under scan the player rests
## on. Drop feet from surface_y + 3 and scan: floor_under must land within ~1 block of surface_y (they describe
## the same play-space surface; a ≤1-block difference is only the snow-cap / top-face convention — "column top
## face" vs "topmost standable"). A REGRESSION that drops the datum lift from ONE of the two paths would open an
## s-sized (~5-7 block) gap, which TOL catches. This proves both collision paths (placement clamp + fall/stand
## scan) use the datum lift consistently — no half-lifted floor.
const TOL := 3.5   # snow/tree caps raise floor_under ≤ ~2 blocks above the bare surface_y top face; an s-sized
                   # (≥4.6 block near facet centre) datum desync between the two paths is well outside TOL.
func _gate_floor_under_agrees(w: WorldManager) -> void:
	var worst := 0.0
	var checked := 0
	for fid in [FA.spawn_facet(), 0, 101, 1500, 2800]:
		if fid < 0 or fid >= FA.facet_count():
			continue
		TC.set_active_facet(fid)
		var cc := FA.centre_cell(fid)
		for d in [[0, 0], [12, 5], [-9, 14], [20, -7], [30, 30], [-25, 8], [6, -22], [40, 40]]:
			var xi: int = cc.x + int(d[0])
			var zi: int = cc.y + int(d[1])
			var sy := w.surface_y(float(xi) + 0.5, float(zi) + 0.5)
			var fu := w.floor_under(float(xi) + 0.5, float(zi) + 0.5, sy + 3.0)
			var err: float = absf(sy - fu)
			if err > worst:
				worst = err
			if err > TOL:
				print("    GAP fid=%d (%d,%d) surface_y=%.3f floor_under=%.3f d=%.3f" % [fid, xi, zi, sy, fu, err])
			checked += 1
	print("  G-FLOOR-UNDER: %d columns; worst |surface_y - floor_under| = %.4f (TOL=%.1f)" % [checked, worst, TOL])
	_ok(checked >= 8, "too few columns compared (%d)" % checked)
	_ok(worst <= TOL, "surface_y (placement) and floor_under (stand/fall) disagree by %.4f (> %.1f) — a datum lift is applied to only one path" % [worst, TOL])

## G-FLOOR-SEAM — both sides of a shared ridge: surface_y == render top on each side (no collision cliff at the
## seam). Samples columns just inside the active facet's four ridges and the mirror column on the neighbour.
func _gate_seam_columns(w: WorldManager) -> void:
	var fid := FA.spawn_facet()
	var cc := FA.centre_cell(fid)
	var worst := 0.0
	var checked := 0
	for slot in 4:
		var offs: Array = [[20, 0], [-20, 0], [0, 20], [0, -20]][slot]
		var xi: int = cc.x + int(offs[0])
		var zi: int = cc.y + int(offs[1])
		# active side
		TC.set_active_facet(fid)
		var sy := w.surface_y(float(xi) + 0.5, float(zi) + 0.5)
		var rt := _render_top(w, fid, xi, zi)
		worst = maxf(worst, absf(sy - rt))
		checked += 1
		# neighbour side: reframe the same world direction into the neighbour's frame, sample there
		var B := FA.seam_neighbour(fid, slot)
		var g := int(TC.facet_profile(fid, xi, zi).x)
		var wdir := FA.lattice_to_world64(fid, float(xi) + 0.5, float(g), float(zi) + 0.5)
		var latB: Array = FA.world_to_lattice64(B, wdir[0], wdir[1], wdir[2])
		var bx := int(round(latB[0]))
		var bz := int(round(latB[2]))
		TC.set_active_facet(B)
		var syB := w.surface_y(float(bx) + 0.5, float(bz) + 0.5)
		var rtB := _render_top(w, B, bx, bz)
		worst = maxf(worst, absf(syB - rtB))
		checked += 1
	print("  G-FLOOR-SEAM: %d seam-adjacent columns (both sides); worst |surface_y - render_top| = %.4f" % [checked, worst])
	_ok(worst <= EPS, "surface_y diverges from render at a seam column by %.4f" % worst)
