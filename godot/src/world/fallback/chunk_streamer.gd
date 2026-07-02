class_name ChunkStreamer
extends Node3D
## Streams heightmap chunks around the player for the pure-GDScript path.
##
## Keeps a ring of MeshInstance3D chunks within the render radius, building a
## budgeted number per frame (so the first-load hitch is spread out) and freeing
## chunks that fall outside the radius. Chunk meshes carry absolute world-space
## vertices, so every instance sits at the origin with an identity transform.

## Chunks meshed per frame while catching up. Keeps frame time bounded.
const BUILD_BUDGET := 4

var _material: Material
var _radius_chunks: int
var _center := Vector2i(2147483647, 0)          # force first update
var _chunks := {}                                # Vector2i -> MeshInstance3D
var _queue: Array[Vector2i] = []                 # pending builds, nearest first

func setup(material: Material) -> void:
	_material = material
	var n := TerrainConfig.CHUNK_SIZE
	_radius_chunks = int(ceil(float(TerrainConfig.RENDER_RADIUS_BLOCKS) / n))

## Call every frame with the player's world position.
func update_center(player_pos: Vector3) -> void:
	var n := TerrainConfig.CHUNK_SIZE
	var c := Vector2i(int(floor(player_pos.x / n)), int(floor(player_pos.z / n)))
	if c == _center:
		return
	_center = c
	_refresh_active_set()

func _refresh_active_set() -> void:
	# Free chunks beyond the radius (+1 hysteresis to avoid thrashing at edges).
	var keep_r := _radius_chunks + 1
	for key: Vector2i in _chunks.keys():
		var d := key - _center
		if absi(d.x) > keep_r or absi(d.y) > keep_r:
			var inst: Node = _chunks[key]
			if is_instance_valid(inst):
				inst.queue_free()
			_chunks.erase(key)

	# Enqueue missing chunks within the radius, nearest to the player first.
	var pending: Array[Vector2i] = []
	for dz in range(-_radius_chunks, _radius_chunks + 1):
		for dx in range(-_radius_chunks, _radius_chunks + 1):
			var key := _center + Vector2i(dx, dz)
			if not _chunks.has(key):
				pending.append(key)
	pending.sort_custom(func(a, b):
		return (a - _center).length_squared() < (b - _center).length_squared())
	_queue = pending

func _process(_delta: float) -> void:
	var built := 0
	while built < BUILD_BUDGET and not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if _chunks.has(key):
			continue
		_build_chunk(key)
		built += 1

func _build_chunk(key: Vector2i) -> void:
	var mesh := ChunkMesher.build(key.x, key.y, _material)
	var inst := MeshInstance3D.new()
	inst.name = "Chunk_%d_%d" % [key.x, key.y]
	if mesh != null:
		inst.mesh = mesh
	add_child(inst)
	_chunks[key] = inst

## True once the initial ring around the player has finished building.
func is_ready_around_player() -> bool:
	return _queue.is_empty() and not _chunks.is_empty()
