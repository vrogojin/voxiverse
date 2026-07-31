extends SceneTree
## COSMOS FALL-THROUGH FIX gate (FP_TP_FLOOR_WELD) — a dev GEO-teleport that drops from altitude must land on the
## RESOLVED OWNER surface, never sink through it to the deep underground fill.
##
## Root cause it defends: FP_DEV_TP_REFRAME resolves + places the owner facet CONTAINED (verify_dev_teleport_owner:
## min own_dist ≫ −HYST, no crossing fires headlessly), yet a facet crossing that fires MID-FALL live reframes the
## player into a NEIGHBOUR lattice; from that frame both surface_y and floor_under resolve the neighbour's DEEP column
## (≈ −6360 seafloor), so the fall-through guard (_dev_land_clamp, which reads surface_y in the CURRENT frame) never
## catches → the player free-falls through the true surface and settles on the deep fill (deepslate ≈ −18). The fix
## WELDS the post-teleport landing to the owner facet (re-assert + suppress crossings) so the floor stays on the owner
## column and the guard catches at the true surface.
##
## RUN (flags ON):
##   sed -i 's/const FACETED := false/const FACETED := true/; \
##           s/const FP_DEV_TP_REFRAME := false/const FP_DEV_TP_REFRAME := true/; \
##           s/const FP_TP_FLOOR_WELD := false/const FP_TP_FLOOR_WELD := true/; \
##           s/const FP_DATUM_BAKE := false/const FP_DATUM_BAKE := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import   # (twice on a fresh worktree)
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_teleport_floor.gd
##   then REVERT. Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const PlayerCls := preload("res://src/player/player.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _dir(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(clampf(lat_deg, -90.0, 90.0))
	var lon := deg_to_rad(lon_deg)
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))

# Resolve the owner facet + integer column for a lat/lon exactly as _dev_teleport_geo does (facet_of_dir).
func _owner(lat_deg: float, lon_deg: float) -> Dictionary:
	var d := _dir(lat_deg, lon_deg).normalized()
	var fid := FA.facet_of_dir(CubeSphere.DVec3.new(d.x, d.y, d.z))
	var w := d * FA.R_BLOCKS
	var l: Array = FA.world_to_lattice64(fid, w.x, w.y, w.z)
	return {"fid": fid, "x": floori(l[0]), "z": floori(l[2])}

func _initialize() -> void:
	print("=== verify_teleport_floor (FP_TP_FLOOR_WELD: geo-teleport drop lands on the owner surface, never the deep fill) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true (+ FP_TP_FLOOR_WELD, FP_DEV_TP_REFRAME) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	TC.set_active_facet(FA.spawn_facet())
	var w: WorldManager = WorldManager.new(); w.name = "TPFloorWM"; get_root().add_child(w)
	print("  FP_TP_FLOOR_WELD=%s FP_DEV_TP_REFRAME=%s FP_DATUM_BAKE=%s" % [
		str(CubeSphere.FP_TP_FLOOR_WELD), str(CubeSphere.FP_DEV_TP_REFRAME), str(CubeSphere.FP_DATUM_BAKE)])

	_gate_agree(w)
	_gate_flip_disagrees(w)
	_gate_weld_heals(w)
	await _gate_arm_wiring(w)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## G-TPF-AGREE — the reported repro column (lat 8 / lon 2 → fid 348). At the OWNER active facet, the falling player's
## floor query (floor_under from altitude feet) equals the analytic surface_y — NO ~24-block disagreement — and the
## surface is a positive above-ground top (never the −18/−17 deep fill).
func _gate_agree(w: WorldManager) -> void:
	var oc := _owner(8.0, 2.0)
	var fid: int = int(oc["fid"]); var xi: int = int(oc["x"]); var zi: int = int(oc["z"])
	var xf := float(xi) + 0.5; var zf := float(zi) + 0.5
	TC.set_active_facet(fid)
	var sy := w.surface_y(xf, zf)
	var fu := w.floor_under(xf, zf, sy + 30.0)   # falling player: feet at the placed alt-30 pose
	print("  G-TPF-AGREE: fid=%d col=(%d,%d) surface_y=%.2f floor_under(feet=surf+30)=%.2f Δ=%.3f" % [fid, xi, zi, sy, fu, sy - fu])
	_ok(fid == 348, "lat8/lon2 owner fid=%d (expected 348) — atlas changed; update the gate column" % fid)
	_ok(sy > 0.0, "owner surface_y=%.2f is not a positive above-ground top (the buried symptom)" % sy)
	_ok(absf(sy - fu) < 1.0, "floor_under DISAGREES with surface_y by %.2f at the owner column (the fall-through gap)" % (sy - fu))

## G-TPF-FLIP-DISAGREES (teeth / falsifier) — the mechanism the weld defends MUST be real: with the active frame flipped
## to a ridge-NEIGHBOUR (what a mid-fall crossing does), surface_y at the SAME owner column resolves the neighbour's DEEP
## seafloor — hundreds of blocks below the owner surface. If this class were empty there'd be nothing to weld.
func _gate_flip_disagrees(w: WorldManager) -> void:
	var oc := _owner(8.0, 2.0)
	var fid: int = int(oc["fid"]); var xi: int = int(oc["x"]); var zi: int = int(oc["z"])
	var xf := float(xi) + 0.5; var zf := float(zi) + 0.5
	TC.set_active_facet(fid)
	var owner_sy := w.surface_y(xf, zf)
	var worst := 0.0; var example := ""
	for slot in range(4):
		var nb := FA.seam_neighbour(fid, slot)
		TC.set_active_facet(nb)
		var nsy := w.surface_y(xf, zf)
		var drop := owner_sy - nsy
		if drop > worst:
			worst = drop; example = "neighbour fid=%d surface_y=%.1f (owner %.1f, drop %.1f)" % [nb, nsy, owner_sy, drop]
	TC.set_active_facet(fid)
	print("  G-TPF-FLIP: worst neighbour-frame drop at the owner column = %.1f blocks; %s" % [worst, example])
	_ok(worst > 100.0, "a neighbour-frame flip does NOT strand the guard (worst drop %.1f ≤ 100) — the weld would be moot" % worst)

## G-TPF-WELD-HEALS — re-asserting the owner facet (exactly what FP_TP_FLOOR_WELD does every landing frame) RESTORES the
## correct floor after a simulated mid-fall flip: floor_under at the owner column returns the owner surface again.
func _gate_weld_heals(w: WorldManager) -> void:
	var oc := _owner(8.0, 2.0)
	var fid: int = int(oc["fid"]); var xi: int = int(oc["x"]); var zi: int = int(oc["z"])
	var xf := float(xi) + 0.5; var zf := float(zi) + 0.5
	TC.set_active_facet(fid)
	var owner_sy := w.surface_y(xf, zf)
	# simulate the mid-fall crossing: active flips to a neighbour, the floor goes deep
	var nb := FA.seam_neighbour(fid, 0)
	TC.set_active_facet(nb)
	var flipped := w.floor_under(xf, zf, owner_sy + 30.0)
	# the weld's per-frame re-assert: active := owner
	TC.set_active_facet(fid)
	var healed := w.floor_under(xf, zf, owner_sy + 30.0)
	print("  G-TPF-WELD: flipped floor=%.1f → re-assert owner → floor=%.2f (owner surface=%.2f)" % [flipped, healed, owner_sy])
	_ok(absf(healed - owner_sy) < 1.0, "re-asserting the owner facet did NOT restore the surface floor (Δ=%.2f)" % (healed - owner_sy))
	_ok(owner_sy - flipped > 100.0, "the simulated flip did not actually strand the floor (drop %.1f) — heal is untested" % (owner_sy - flipped))

## G-TPF-ARM — the SHIPPED wiring: remote_teleport("geo", 8, 2, 30) arms the weld latch on the resolved owner
## (_tp_owner_fid == owner, _tp_land_active true) so _physics_process welds the ensuing fall. Proves the fix is
## wired through the real player, not just the gate's analytic mirror.
func _gate_arm_wiring(w: WorldManager) -> void:
	var oc := _owner(8.0, 2.0)
	var pl = PlayerCls.new()
	pl.world = w
	get_root().add_child(pl)
	await process_frame
	pl.frozen = true
	var ok: bool = pl.remote_teleport("geo", 8.0, 2.0, 30.0)
	print("  G-TPF-ARM: remote_teleport(geo 8,2,30)=%s _tp_owner_fid=%s _tp_land_active=%s _dev_land_guard=%s" % [
		str(ok), str(pl._tp_owner_fid), str(pl._tp_land_active), str(pl._dev_land_guard)])
	_ok(ok, "remote_teleport(geo) returned false (no landing)")
	_ok(int(pl._tp_owner_fid) == int(oc["fid"]), "weld latch owner fid=%s != resolved owner %s" % [str(pl._tp_owner_fid), str(oc["fid"])])
	# The drop is pending (guard armed, no meshed-hover settle headless) ⇒ the weld must be armed to protect it.
	_ok(pl._tp_land_active == (pl._dev_land_guard and not pl._settle_active),
		"weld latch state inconsistent with the pending-landing condition")
	_ok(not pl._dev_land_guard or pl._tp_land_active, "a pending drop landing is NOT welded (guard armed but weld off)")
	pl.free()
