extends SceneTree
## DIAGNOSTIC PROBE (fix/voxiverse-fall-altrate): time each per-frame subsystem while the camera
## descends at controlled rates, to find the cost that SCALES WITH DESCENT SPEED (live: 49 fps hover
## -> 26 fps slow descent -> 7 fps free-fall). Not a gate; prints per-frame us for each subsystem at
## hover (drate=0), slow (drate=SLOW), fast (drate=FAST). Run with the deploy flags sed'd on.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const SKY := preload("res://src/cosmos/cosmos_sky.gd")
const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

# A stub camera provider whose altitude we drive.
class CamStub extends Node:
	var alt := 800.0     # radial altitude above R (blocks); world origin = planet centre
	var _x := 0.0
	var _z := 0.0
	func camera_global_transform() -> Transform3D:
		var r := FacetAtlas.R_BLOCKS + alt
		return Transform3D(Basis.IDENTITY, Vector3(_x, r, _z))

func _t() -> int:
	return Time.get_ticks_usec()

func _initialize() -> void:
	print("=== probe_fall_altrate ===")
	print("  FACETED=%s FP_SN3_MAIN_LIVE=%s FP_SCALED_BODY=%s FP_FOG_ARBITER=%s ATMO_VISUAL_RAMP=%s FP_SUN_PATHLIGHT=%s FP_ATMO_SHELL=%s FP_LIGHT_ABSOLUTE=%s SN_SUN_OCCLUSION=%s FP_ATMO_SPACE_ZERO=%s"
		% [str(CubeSphere.FACETED), str(CubeSphere.FP_SN3_MAIN_LIVE), str(CubeSphere.FP_SCALED_BODY),
		   str(CubeSphere.FP_FOG_ARBITER), str(CubeSphere.ATMO_VISUAL_RAMP), str(CubeSphere.FP_SUN_PATHLIGHT),
		   str(CubeSphere.FP_ATMO_SHELL), str(CubeSphere.FP_LIGHT_ABSOLUTE), str(CubeSphere.SN_SUN_OCCLUSION),
		   str(CubeSphere.FP_ATMO_SPACE_ZERO)])
	TC.warm_up()
	FA.warm_up()

	# --- Build a live sky (atmosphere path exercised only under the flags above) ---
	var clock := EPH.CosmosClock.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.fog_enabled = true
	var cam := CamStub.new()
	get_root().add_child(cam)
	var sky := SKY.new()
	get_root().add_child(sky)
	sky.setup(clock, env, cam)
	await process_frame

	# --- Build a WorldManager to time update_streaming (needs FACETED active facet) ---
	var wm: WorldManager = null
	if CubeSphere.FACETED:
		var A := FA.spawn_facet()
		TC.set_active_facet(A)
		wm = WorldManager.new(); wm.name = "ProbeWM"; get_root().add_child(wm)
		wm.set_cosmos_clock(clock)
		for _rf in range(4):
			await process_frame

	var N := 400
	for regime in [["HOVER", 0.0], ["SLOW", 4.0], ["FAST", 30.0]]:
		var label: String = regime[0]
		var drate: float = regime[1]     # blocks/frame descent
		cam.alt = 800.0
		var dt := 1.0 / 60.0
		# warm one pass so lazy caches settle
		clock.advance(dt); sky._update_sky(clock.now())
		var sky_us := 0
		var stream_us := 0
		var cc := FA.centre_cell(TC.active_facet()) if wm != null else Vector2i(0, 0)
		for i in range(N):
			cam.alt = maxf(cam.alt - drate, 64.0)
			clock.advance(dt)
			var t0 := _t()
			sky._update_sky(clock.now())
			sky_us += _t() - t0
			if wm != null:
				var r := FA.R_BLOCKS + cam.alt
				var pos := Vector3(float(cc.x) + 0.5, r, float(cc.y) + 0.5)
				var t1 := _t()
				wm.update_streaming(pos)
				stream_us += _t() - t1
		print("  %-6s drate=%4.0f b/f : sky._update_sky = %6.2f us/frame | update_streaming = %6.2f us/frame"
			% [label, drate, float(sky_us) / N, float(stream_us) / N])

	print("=== done ===")
	quit(0)
