class_name PerfHUD
extends CanvasLayer
## Always-on PERFORMANCE OVERLAY (diagnostic) — top-right. Surfaces the real bottleneck
## behind frame drops (esp. when water / voxel chunks stream in) so we measure instead of
## guess. Reads Godot's `Performance` monitors + godot_voxel's `VoxelEngine.get_stats()`.
##
## WHY THIS EXISTS / HOW TO READ IT:
## A steady average FPS with a game that FEELS terrible = frame-time SPIKES (hitches), not a
## low frame rate. A single 150 ms stall once a second is invisible to an averaged FPS number
## (it recovers within the 0.25 s window) but feels awful. So the HEADLINE numbers here are the
## spike hunters, not average FPS:
##   * worst ms  — the SLOWEST single frame in the last window. This is the hitch. If avg FPS
##                 reads 60 but `worst` is 150 ms, that 150 ms stall is your "performance drop".
##   * min FPS   — 1000/worst-ms; the instantaneous floor the average hides.
##   * hitches   — running count of frames slower than HITCH_MS (33 ms ≈ below 30 fps). A rising
##                 counter while you stand still near water = periodic stalls.
##   * stream/s  — voxel blocks meshed+uploaded this second. A spike in `worst ms` that lines up
##                 with a jump in `stream/s` ⇒ the stall is main-thread MESH UPLOAD / collider
##                 rebuild as chunks arrive (CPU main-thread), not GPU and not average frame rate.
##   * proc/phys — main-thread script + physics ms/frame (averaged by the engine).
##   * draws/prims — per-frame draw calls + primitives (GPU load / overdraw).
##   * vox mesh/main/gpu — godot_voxel PENDING task counts (worker saturation / streaming lag).
##
## LOGS: every window a `[PERF]` line is print()ed (browser DevTools console on web); every frame
## slower than LOG_MS a loud `[PERF-HITCH]` line with context is print()ed. Copy those to share a
## timeline of the stalls. Purely diagnostic — no gameplay effect; remove once perf is settled.

const HITCH_MS := 33.0    # a frame slower than this (~below 30 fps) counts as a hitch
const LOG_MS := 60.0      # a frame slower than this gets its own loud console line
const WINDOW := 0.25      # display/log refresh window (s)

var _label: Label
var _voxel_engine: Object = null
var _acc := 0.0
var _frames := 0
var _worst := 0.0         # slowest frame (s) in the current window
var _hitches := 0         # total frames slower than HITCH_MS since start
var _last_blocks := -1    # voxel block_count at the previous window (for stream/s)

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
	if delta > _worst:
		_worst = delta
	var dms := delta * 1000.0
	if dms > HITCH_MS:
		_hitches += 1
	# Loud per-hitch line the moment a bad frame lands, with the streaming context that
	# most often explains it (worker backlog + how many blocks are live right now).
	if dms > LOG_MS:
		var mesh_pending := "?"
		var gen_pending := "?"
		if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
			var st: Dictionary = _voxel_engine.call("get_stats")
			var tasks := (st.get("tasks", {}) as Dictionary)
			mesh_pending = str(tasks.get("meshing", 0))
			gen_pending = str(tasks.get("generation", 0))
		print("[PERF-HITCH] %.0f ms frame  vox_gen_backlog=%s  vox_mesh_backlog=%s" % [dms, gen_pending, mesh_pending])

	if _acc < WINDOW:
		return

	var fps := float(_frames) / _acc
	var worst_ms := _worst * 1000.0
	var min_fps := 1000.0 / maxf(worst_ms, 0.001)
	_acc = 0.0
	_frames = 0
	_worst = 0.0

	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	# godot_voxel worker/pool state. NOTE: memory_pools.block_count is a FREE-buffer counter (reads 0
	# even while thousands of blocks generate — it is NOT a live-block count), so the real streaming
	# signal is the TASK BACKLOG: generation + meshing tasks still queued. Backlog draining to 0 == the
	# near field has finished loading. That is the number to watch while chunks stream in.
	var gen_pending := 0
	var mesh_pending := 0
	var main_pending := 0
	var gpu_pending := 0
	if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
		var st: Dictionary = _voxel_engine.call("get_stats")
		var tasks: Dictionary = st.get("tasks", {})
		gen_pending = int(tasks.get("generation", 0))
		mesh_pending = int(tasks.get("meshing", 0))
		main_pending = int(tasks.get("main_thread", 0))
		gpu_pending = int(tasks.get("gpu", 0))
	var backlog := gen_pending + mesh_pending
	# Blocks the backlog drained since the last window → an effective streaming rate (blocks/s).
	var drained := 0
	if _last_blocks >= 0:
		drained = maxi(0, _last_blocks - backlog)
	_last_blocks = backlog
	var stream_per_s := int(round(float(drained) / WINDOW))

	var s := ("FPS %5.1f  min %5.1f\nworst %5.1f ms   hitches %d\ndrained %d /s\n" +
		"proc %5.2f ms   phys %5.2f ms\ndraws %d   prims %s\nvmem %.0f MB\n" +
		"vox backlog: gen %d  mesh %d\nvox pending: main %d  gpu %d") % [
		fps, min_fps, worst_ms, _hitches, stream_per_s,
		proc_ms, phys_ms, draws, _fmt(prims), vmem,
		gen_pending, mesh_pending, main_pending, gpu_pending]
	_label.text = s

	print("[PERF] fps=%.0f min=%.0f worst=%.0fms hitches=%d drained=%d/s proc=%.1f phys=%.1f draws=%d prims=%d vox_gen=%d vox_mesh=%d" % [
		fps, min_fps, worst_ms, _hitches, stream_per_s, proc_ms, phys_ms, draws, prims, gen_pending, mesh_pending])

func _fmt(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.0fk" % (n / 1000.0)
	return str(n)
