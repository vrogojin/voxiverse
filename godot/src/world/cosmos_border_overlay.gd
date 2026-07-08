class_name CosmosBorderOverlay
extends MultiMeshInstance3D
## DEV-ONLY visualization (task #66): bright emissive PILLARS along the current home face's CUBE-FACE
## BORDERS, so the seam edges are visible to walk up to and test the M4 seam-crossing handoff (otherwise
## the borders are invisible and testing is guesswork). CURVED mode only.
##
## The home face spans global cells i,j ∈ [0, n); the chart maps a global column (gi,gj) → window
## (gi−i_org, gj−j_org), so the 4 edges (i=0, i=n, j=0, j=n) are the WINDOW lines x=−i_org, x=n−i_org,
## z=−j_org, z=n−j_org. Placement is recomputed EVERY frame from WorldManager.cosmos_border_lines(), so it
## survives origin re-anchors AND home-face flips: at a flip the home face changes and the borders jump to
## the new face's edges — which is desirable, it lets you SEE the flip happen.
##
## Why pillars (not a surface-hugging line): the GL Compatibility / WebGL2 renderer caps line width at 1px
## (hard to spot at distance), whereas tall vertical markers pierce up through the terrain and read from
## far away — the doc's accepted, cleaner choice. Each pillar is a BoxMesh instance in a MultiMesh, drawn
## with the SAME CosmosBend world-space vertex bend as the terrain (a ShaderMaterial on
## CosmosBend.opaque_shader()), so it sits ON the curved surface consistently with the near field, and is
## rooted to the local surface height so it always emerges from the ground near the player.
##
## FLAT_WORLD / no chart: main.gd never creates this node → zero cost, byte-identical default path.

const DEV_BORDERS := true                  # DEFAULT ON (task #66) — one-line flip to disable; ships to the live site
const PILLAR_SPACING := 8.0                # window units between pillars along an edge
const PILLAR_SPAN := 192.0                 # half-run drawn along each edge, centred on the player's projection
const PILLAR_HEIGHT := 64.0                # tall enough to spot from a distance and over mountains near the seam
const PILLAR_WIDTH := 0.7
const PILLAR_SINK := 6.0                   # start this far BELOW the surface so the pillar visibly pierces up
const DEV_COLOR := Color(1.0, 0.0, 1.0)    # vivid magenta — rare in the world, pops against green/white/blue

var _world: WorldManager
var _player: Node3D

## Wire the overlay to the world (chart source) + player (window position). Builds the shared box + bend
## material and a fixed-size MultiMesh; per-frame we only reposition instances (no allocation churn).
func setup(world: WorldManager, player: Node3D) -> void:
	_world = world
	_player = player

	var box := BoxMesh.new()
	box.size = Vector3(PILLAR_WIDTH, PILLAR_HEIGHT, PILLAR_WIDTH)

	CosmosBend.ensure_globals()
	var mat := ShaderMaterial.new()
	mat.shader = CosmosBend.opaque_shader()
	mat.set_shader_parameter("use_texture", false)
	mat.set_shader_parameter("use_vertex_color", false)
	mat.set_shader_parameter("albedo_color", DEV_COLOR)
	mat.set_shader_parameter("emission_color", Vector3(DEV_COLOR.r, DEV_COLOR.g, DEV_COLOR.b))
	mat.set_shader_parameter("emission_energy", 1.0)
	material_override = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = _max_instances()
	multimesh = mm

	# The bend shader displaces vertices to arbitrary world positions at draw time and pillars sit anywhere
	# in the ±n window range, so the CPU-side AABB can't predict them — pin a huge custom AABB so the node is
	# never wrongly frustum-culled. It is ~200 instances (far ones bend below the horizon / past camera far
	# and simply don't rasterize), so "always submitted" costs nothing measurable.
	custom_aabb = AABB(Vector3(-12000.0, -512.0, -12000.0), Vector3(24000.0, 1024.0, 24000.0))
	set_process(true)

func _max_instances() -> int:
	var per_edge := int(ceil(2.0 * PILLAR_SPAN / PILLAR_SPACING)) + 2
	return 4 * per_edge

func _process(_delta: float) -> void:
	if _world == null or _player == null:
		return
	var mm := multimesh
	if mm == null:
		return
	var lines: Array = _world.cosmos_border_lines()
	var pp := _player.global_position
	var idx := 0
	for line: Dictionary in lines:                 # empty in FLAT / no chart → all instances hidden below
		idx = _emit_edge(mm, idx, line, pp)
	# Collapse any unused instances to a zero-scale (degenerate → not rasterized) transform.
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	while idx < mm.instance_count:
		mm.set_instance_transform(idx, hidden)
		idx += 1

## Lay pillars along one edge, spaced PILLAR_SPACING apart over a ±PILLAR_SPAN run centred on the player's
## projection onto the edge and clamped to the edge's real extent [lo, hi]. Each pillar is rooted to the
## local surface height so it emerges from the ground (pre-bend window space; the shared bend then curves
## pillar and terrain together). Returns the next free instance index.
func _emit_edge(mm: MultiMesh, idx: int, line: Dictionary, pp: Vector3) -> int:
	var axis: String = line["axis"]
	var pos := float(line["pos"])
	var lo := float(line["lo"])
	var hi := float(line["hi"])
	var centre := pp.z if axis == "x" else pp.x
	var start := maxf(centre - PILLAR_SPAN, lo)
	var end := minf(centre + PILLAR_SPAN, hi)
	var t := start
	while t <= end + 0.001 and idx < mm.instance_count:
		var col_x := pos if axis == "x" else t
		var col_z := t if axis == "x" else pos
		var base := _world.surface_y(col_x, col_z) - PILLAR_SINK   # root below the surface so it pierces up
		var origin := Vector3(col_x, base + PILLAR_HEIGHT * 0.5, col_z)
		mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY, origin))
		idx += 1
		t += PILLAR_SPACING
	return idx
