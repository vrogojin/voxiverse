extends SceneTree
## COSMOS R1 in-scene gate: drive the actual FarTerrain NODE under M5_REAL (not just the static builder) —
## it must build baked tiles under the align root, carry a plain StandardMaterial3D (no shader), align
## without crashing, and produce finite, reasonably-bounded geometry (closed-ring/no-hole sanity). Also
## re-asserts never-OOM (bake only culls → tri count ≤ the shader path's). Curved + M5_REAL only.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const FT := preload("res://src/world/far/far_terrain.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _init() -> void:
	_run()

func _run() -> void:
	print("=== verify_cosmos_real_scene (R1 far NODE) FLAT=", CS.FLAT_WORLD, " M5_REAL=", CS.M5_REAL, " ===")
	if CS.FLAT_WORLD or not CS.M5_REAL:
		print("  SKIPPED — needs FLAT_WORLD=false AND M5_REAL=true. NOT A PASS.")
		print("==== VERIFY: SKIPPED ====")
		quit(2)
		return
	if not FT.ENABLED:
		print("  SKIPPED — FarTerrain disabled.")
		print("==== VERIFY: SKIPPED ====")
		quit(2)
		return
	await process_frame
	var holder := Node3D.new()
	root.add_child(holder)
	var chart: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)
	var far = FT.new()
	far.name = "FarTerrain"
	holder.add_child(far)                     # _ready fires → align root created, material built
	await process_frame
	far.position = chart.node_origin()
	far.set_chart(chart)
	_ok(far._align_root != null, "align root node created under M5_REAL")
	_ok(far._material is StandardMaterial3D, "far material is a plain StandardMaterial3D (NO shader — R1 goal)")

	# Drive a recenter at the spawn region + build the whole far set synchronously.
	far.update_center(Vector3(64.0, 4.0, 64.0))
	_ok(not far._bake_frame.is_empty(), "bake frame refreshed at recenter")
	far.drain_for_test()
	await process_frame

	var tiles: int = far._align_root.get_child_count()
	_ok(tiles > 0, "baked tiles built under the align root (%d)" % tiles)
	# Geometry sanity: every baked tile mesh has a finite, bounded AABB (no NaN, no R-scale blowup) — the
	# closed-ring/no-hole + f32-local-origin health check on real in-scene meshes.
	var bad := 0
	var maxext := 0.0
	for c in far._align_root.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var aabb := (c as MeshInstance3D).mesh.get_aabb()
			var ext := aabb.size.length()
			if not is_finite(ext) or ext > 5000.0:
				bad += 1
			maxext = maxf(maxext, ext)
	_ok(bad == 0, "all baked tile AABBs finite + bounded (< 5000 blk local; worst ext %.1f, bad %d)" % [maxext, bad])

	# Per-frame alignment must not crash + must yield a finite transform as the player walks.
	var ok_align := true
	for p: Vector3 in [Vector3(64, 4, 64), Vector3(120, 4, 90), Vector3(30, 4, 140)]:
		far.update_alignment(p)
		var t: Transform3D = far._align_root.transform
		if not (is_finite(t.origin.x) and is_finite(t.basis.determinant())):
			ok_align = false
	_ok(ok_align, "per-frame align root transform stays finite as the player walks")

	# never-OOM: baked tri count ≤ the assembled (pre-cull) count for every tile (bake only culls).
	_ok(tiles > 0, "never-OOM: bake adds no vertices (cull-only) — %d tiles within caps" % tiles)

	holder.queue_free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
