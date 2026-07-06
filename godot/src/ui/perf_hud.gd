class_name PerfHUD
extends CanvasLayer
## Always-on PERFORMANCE OVERLAY (diagnostic) — top-right. Surfaces the real bottleneck
## behind frame drops (esp. when water / voxel chunks stream in) so we measure instead of
## guess. Reads Godot's `Performance` monitors + godot_voxel's `VoxelEngine.get_stats()`.
##
## Reading it:
##   * FPS / frame ms   — the symptom.
##   * proc / phys ms   — MAIN-THREAD script + physics cost per frame. If these spike when
##                        water loads → CPU main-thread bound (collider, scripts).
##   * draws / prims    — per-frame draw calls + primitives (≈ vertices). If these balloon
##                        while proc/phys stay low → GPU-bound (translucent-water overdraw).
##   * vox mesh/main/gpu — godot_voxel PENDING task counts. If `mesh` piles up → the (web:
##                        single) voxel worker is saturated: chunks stream in slowly (this is
##                        streaming lag, not a main-thread frame drop, but it feels laggy).
##   * blocks / vmem    — voxel block count + video memory.
##
## Purely diagnostic: no gameplay effect. Remove or gate behind a key once perf is settled.

var _label: Label
var _voxel_engine: Object = null
var _acc := 0.0
var _frames := 0
var _fps := 0.0
var _proc_ms := 0.0
var _phys_ms := 0.0

func _ready() -> void:
	layer = 100
	var panel := PanelContainer.new()
	panel.modulate = Color(1, 1, 1, 0.9)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "PERF (diagnostic)"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(0.8, 0.85, 0.95)
	vbox.add_child(title)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_label)

	if Engine.has_singleton("VoxelEngine"):
		_voxel_engine = Engine.get_singleton("VoxelEngine")

func _process(delta: float) -> void:
	_acc += delta
	_frames += 1
	if _acc < 0.25:
		return
	_fps = float(_frames) / _acc
	_acc = 0.0
	_frames = 0
	_proc_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_phys_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	var s := "FPS %5.1f  (%.1f ms/frame)\nproc %5.2f ms   phys %5.2f ms\ndraws %d   prims %s\nvmem %.0f MB" % [
		_fps, 1000.0 / maxf(_fps, 0.001), _proc_ms, _phys_ms, draws, _fmt(prims), vmem]

	if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
		var st: Dictionary = _voxel_engine.call("get_stats")
		var tasks: Dictionary = st.get("tasks", {})
		var mem: Dictionary = st.get("memory_pools", {})
		s += "\nvox pending: mesh %s  main %s  gpu %s\nvox blocks %s" % [
			str(tasks.get("meshing", 0)), str(tasks.get("main_thread", 0)),
			str(tasks.get("gpu", 0)), str(mem.get("block_count", 0))]

	_label.text = s

func _fmt(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.0fk" % (n / 1000.0)
	return str(n)
