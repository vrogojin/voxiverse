class_name PerfLogger
extends Node
## Diagnostic (temporary): every INTERVAL seconds prints one console line of runtime
## metrics so a live browser session can be characterised without guessing. Reports
## FPS avg/MIN/max over the window (MIN catches the per-second "wave"/jerk dips),
## main-thread frame + physics time, render draw-calls/primitives, video + static
## memory, object/node/orphan counts, and the active loose-VoxelBody count. All values
## come from the global Performance monitors + a read-only child scan (zero engine
## coupling), so this is cheap and safe to leave running during diagnosis. Remove when
## the perf work is done.

const INTERVAL := 1.0

var _world: Node
var _accum := 0.0
var _frames := 0
var _fps_min := 1.0e9
var _fps_max := 0.0

func setup(world: Node) -> void:
	_world = world

func _process(delta: float) -> void:
	var fps := 1.0 / maxf(delta, 0.0001)
	_fps_min = minf(_fps_min, fps)
	_fps_max = maxf(_fps_max, fps)
	_frames += 1
	_accum += delta
	if _accum < INTERVAL:
		return
	var avg := float(_frames) / _accum
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var smem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orph := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("[perf] fps avg=%.1f MIN=%.1f max=%.1f | frame=%.1fms phys=%.1fms | draws=%d prims=%d | vmem=%.1fMB smem=%.1fMB | obj=%d node=%d orph=%d | bodies=%d" % [
		avg, _fps_min, _fps_max, frame_ms, phys_ms, draws, prims,
		vmem, smem, objs, nodes, orph, _count_bodies()])
	_accum = 0.0
	_frames = 0
	_fps_min = 1.0e9
	_fps_max = 0.0

## Active loose VoxelBody count (read-only child scan of the WorldManager).
func _count_bodies() -> int:
	if _world == null:
		return 0
	var n := 0
	for c in _world.get_children():
		if c is VoxelBody:
			n += 1
	return n
