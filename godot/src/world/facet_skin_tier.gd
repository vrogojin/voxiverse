class_name FacetSkinTier
extends Node3D
## COSMOS SEAMLESS-SCALES §4/§10 C3 — the heightfield SKIN tier (flag CubeSphere.FP_SKIN_TIER).
##
## THE GAP IT FILLS. Between the near voxel field (0..~128 blocks — FacetLodMesher / FacetSlots) and the
## whole-planet far-ring backstop (~12.5-block cells, FP_FARRING_FULL_COVER) there is a resolution gap:
## post-L5 the voxel meshes still ARRIVE over ~1 s and until they do the ground shape is only the coarse
## backstop (the obs-2/3 "the ground changes as blocks arrive" pop). The skin is a cheap per-column
## heightfield that covers that annulus IMMEDIATELY from `sample_columns` (§7.2 item 2: one C++ call per
## tile, ~1-3 ms) so the surroundings are visually complete in ~1 s instead of ~45 s.
##
## COMPOSITION (SEAMLESS-SCALES §0.5 / §5.1 — overlap + shared sampling + sink, NOT a cross-fade). The
## skin is built in ABSOLUTE planet coords (like the far ring) and SUNK `SINK` blocks radially inward, so
## the opaque near voxels strictly OVERDRAW it (a voxel block arriving changes the surface by <= the sink
## bias, sub-pixel — never a gap) and it OVERDRAWS the far-ring backstop (finer wins where present; the
## backstop is already correct where the skin has not reached). No alpha, no z-fight.
##
## ONE-SAMPLER LAW (§7.1). Every height/biome/water/colour comes from `_sampler` — a Callable that routes
## to the ONE worldgen core: the compiled VoxelGeneratorCosmos.sample_columns when present, else the
## GDScript oracle (TerrainConfig.column_profile + FarPalette, byte-equal to the C++ path by G-CG-COLUMNS).
## There is NO independent height function here; a second one would crack at a facet ridge.
##
## NEVER-OOM (§10 C3 ledger). A HARD `MAX_BYTES` ceiling (8 MB). Tiles are added nearest-first and the
## farthest are evicted when the budget would be exceeded — memory safety outranks coverage, so if the
## full 256 annulus does not fit at pitch 1 the skin covers LESS (the far ring backstop still covers the
## rest coarsely); it never grows past the ceiling. CDLOD morph, pitch-2/4/8 extension rings and tree
## impostors are LATER stages (§4.2/§4.3) and are deliberately NOT built here — but each tile vertex is
## laid out so a parent-pitch height can be added later without reshaping the mesh.
##
## Flag OFF (default) == byte-identical: WorldManager never creates this node, so nothing changes. FACETED
## only (like FacetFarRing) — the flat world has no facets/atlas; under FLAT the node is never created.

const TILE := 32                     # columns per tile edge (pitch 1). Adjacent tiles SHARE their boundary
                                     # column (tile tx spans [tx·TILE .. tx·TILE+TILE] inclusive), so a
                                     # shared vertex is sampled from the SAME integer (fid,x,z) on both —
                                     # bit-identical by construction (the shared-edge rule, §7 / G-SKIN-EDGE).
const SINK := 1.5                    # blocks pushed radially inward, so the near voxels overdraw the skin
                                     # (SEAMLESS-SCALES §5.1; the far ring's BACKSTOP_SINK is the same idea).
const R_INNER := 64.0                # skip tiles wholly inside this radius: the near voxel disc (0..~128)
                                     # already covers there, so spending the budget on the 96..256 annulus
                                     # (where the arriving-mesh frontier leaves the coarse backstop showing)
                                     # reaches much further out. A one-tile overlap is kept so the skin still
                                     # underlies the near disc's edge (no ring gap while meshes stream in).
const R_OUTER := 256.0               # target coverage radius (blocks). Actual reach is capped by MAX_BYTES.
const MAX_BYTES := 8 * 1024 * 1024   # §10 C3 hard ceiling. Bound tile count × tile bytes; evict farthest.

var _sampler: Callable               # (fid:int, packed:PackedInt64Array) -> {heights,biomes,water,colors}
var _sampler_obj: Object = null      # STRONG ref to the sampler's object (the compiled generator is a
                                     # RefCounted a Callable does NOT keep alive) — held so it is not freed
                                     # out from under _sampler mid-session (else every sample returns null).
var _active_fid := -1
var _anchor_offset: Vector3 = Vector3.ZERO   # fixed-frame floating-origin shift, mirrored from the far ring
var _mat: StandardMaterial3D
var _tiles: Dictionary = {}          # key "fid:tx:tz" -> {mi:MeshInstance3D, bytes:int, dist:float}
var _bytes := 0
var _last_center := Vector3(1e18, 1e18, 1e18)   # last player world pos an update scheduled from

# --- lifecycle -----------------------------------------------------------------------------------

## Build this epoch's sampler and stand the skin up. The compiled generator (a RefCounted a Callable does
## NOT keep alive) is held in the `_sampler_obj` MEMBER from the moment it is created, so it is never freed
## out from under `_sampler` — the bug of returning only a Callable and letting the gen die. Falls back to
## the GDScript oracle (byte-equal by G-CG-COLUMNS) when the compiled class is absent.
func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_sampler_obj = _build_cpp_gen(active_fid)
	if _sampler_obj != null:
		_sampler = Callable(_sampler_obj, "sample_columns")
	else:
		push_warning("FacetSkinTier: VoxelGeneratorCosmos absent — using the GDScript oracle sampler (slow).")
		_sampler = Callable(FacetSkinTier, "gd_sample")
	_mat = _make_material()
	transform = _placement_xform()

## Crossing: the active facet changed. Tiles are keyed by fid so they PERSIST across a crossing (a
## neighbour facet's tiles stay valid); only the placement (identity under the fixed frame) is re-set.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = _placement_xform()

## Fixed-frame re-anchor: slide the absolute skin mesh by −A in lockstep with PlanetRoot + the far ring.
func shift_anchor(a: Vector3) -> void:
	if not _fixed_frame_on():
		return
	_anchor_offset += a
	transform = _placement_xform()

func _fixed_frame_on() -> bool:
	return CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL

## Same placement law as FacetFarRing: identity (minus the re-anchor offset) under the fixed frame, so the
## ABSOLUTE-coord mesh renders in the scene frame; else T_active⁻¹ (re-place absolute into active-lattice).
func _placement_xform() -> Transform3D:
	if _fixed_frame_on():
		return Transform3D(Basis.IDENTITY, -_anchor_offset)
	return FacetAtlas.facet_transform(_active_fid).affine_inverse()

# --- scheduling ----------------------------------------------------------------------------------

## Per-frame (from WorldManager.update_streaming): schedule the tiles whose facet columns fall within
## R_OUTER of the player, nearest-first, under the byte ceiling; evict tiles that fell out of range or
## past the budget. `player_lattice` is the player's (x,y,z) in the ACTIVE facet lattice (the frame
## WorldManager already works in); `fids` are the candidate facets to skin (active + front neighbours).
func update(active_fid: int, player_lattice: Vector3, fids: PackedInt32Array) -> void:
	_active_fid = active_fid
	var pw := _lattice_world(active_fid, player_lattice.x, player_lattice.y, player_lattice.z)
	# Small hysteresis: only reschedule when the player moved enough to matter (avoids per-frame churn).
	if pw.distance_to(_last_center) < float(TILE) * 0.5 and _tiles.size() > 0:
		return
	_last_center = pw

	# Rank every in-range tile by distance, build nearest-first until the budget binds.
	var wanted := _rank_tiles(pw, fids)          # Array of [dist, fid, tx, tz], sorted ascending
	var keep := {}
	for entry in wanted:
		var key: String = _key(int(entry[1]), int(entry[2]), int(entry[3]))
		keep[key] = true
		if _tiles.has(key):
			continue
		var m := _build_tile(int(entry[1]), int(entry[2]), int(entry[3]))
		if m.is_empty():
			continue
		var b: int = m["bytes"]
		if _bytes + b > MAX_BYTES:
			# Budget bound: stop adding (the rest of the annulus is the far ring's job). NEVER-OOM.
			(m["mi"] as MeshInstance3D).queue_free()
			break
		add_child(m["mi"])
		m["dist"] = float(entry[0])
		_tiles[key] = m
		_bytes += b
	# Evict tiles no longer wanted (out of range / past budget).
	for key in _tiles.keys():
		if not keep.has(key):
			_evict(key)

## The candidate tiles within R_OUTER of the player, as [dist, fid, tx, tz], sorted nearest-first.
func _rank_tiles(pw: Vector3, fids: PackedInt32Array) -> Array:
	var out: Array = []
	for fid in fids:
		var lo := FacetAtlas.dom_min(fid)
		var hi := FacetAtlas.dom_max(fid)
		var tx0 := int(floor(float(lo.x) / float(TILE)))
		var tx1 := int(floor(float(hi.x) / float(TILE)))
		var tz0 := int(floor(float(lo.y) / float(TILE)))
		var tz1 := int(floor(float(hi.y) / float(TILE)))
		for tx in range(tx0, tx1 + 1):
			for tz in range(tz0, tz1 + 1):
				var cx := tx * TILE + TILE / 2
				var cz := tz * TILE + TILE / 2
				var w := _lattice_world(fid, float(cx), 0.0, float(cz))
				var d := pw.distance_to(w)
				if d >= R_INNER - float(TILE) and d <= R_OUTER + float(TILE):
					out.append([d, fid, tx, tz])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out

func _evict(key: String) -> void:
	var t: Dictionary = _tiles[key]
	_bytes -= int(t["bytes"])
	(t["mi"] as MeshInstance3D).queue_free()
	_tiles.erase(key)

# --- tile construction (the ONE place geometry is made; used by update AND the gate) --------------

## Build facet `fid`'s tile (tx,tz): sample its (TILE+1)² columns in ONE _sampler call, place each column
## vertex at its ABSOLUTE world height SUNK by SINK, colour it from the palette. Returns
## {mi:MeshInstance3D, bytes:int} or null. NOT added to the tree (the caller decides, for budget control).
func _build_tile(fid: int, tx: int, tz: int) -> Dictionary:
	var ox := tx * TILE
	var oz := tz * TILE
	var stride := TILE + 1
	var packed := PackedInt64Array()
	packed.resize(stride * stride)
	var k := 0
	for gj in range(stride):
		for gi in range(stride):
			packed[k] = _pack_xz(ox + gi, oz + gj)
			k += 1
	var res: Dictionary = _sampler.call(fid, packed)
	var heights: PackedFloat32Array = res["heights"]
	var colors: PackedColorArray = res["colors"]
	if heights.size() != stride * stride:
		return {}

	var pos := _positions_from(fid, ox, oz, heights)
	var col := PackedColorArray()
	var nrm := PackedVector3Array()
	col.resize(stride * stride)
	nrm.resize(stride * stride)
	for i in range(stride * stride):
		col[i] = colors[i]
		nrm[i] = Vector3.ZERO

	# Indexed quad grid — two tris/cell, memory-optimal (verts shared) so the 8 MB ceiling reaches further.
	var idx := PackedInt32Array()
	idx.resize(TILE * TILE * 6)
	var q := 0
	for cj in range(TILE):
		for ci in range(TILE):
			var i0 := cj * stride + ci
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			idx[q + 0] = i0; idx[q + 1] = i2; idx[q + 2] = i1
			idx[q + 3] = i1; idx[q + 4] = i2; idx[q + 5] = i3
			q += 6
			_accum_normal(nrm, pos, i0, i2, i1)
			_accum_normal(nrm, pos, i1, i2, i3)
	for i in range(nrm.size()):
		var n := nrm[i]
		nrm[i] = n.normalized() if n.length_squared() > 0.0 else Vector3.UP

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.name = _key(fid, tx, tz)

	var bytes := pos.size() * 12 + nrm.size() * 12 + col.size() * 16 + idx.size() * 4
	return {"mi": mi, "bytes": bytes, "dist": 0.0}

## THE per-vertex placement (the ONE geometry rule, shared by _build_tile and the shared-edge gate):
## each column's ABSOLUTE world surface point at its sampled height, SUNK SINK blocks radially inward.
## `heights` is the (stride×stride) g array from a _sampler call. Because a column's placement depends
## ONLY on its integer (fid, ox+gi, oz+gj) — never on the tile it belongs to — two adjacent tiles put
## their shared boundary column at bit-identical positions (the shared-edge invariant, G-SKIN-EDGE).
func _positions_from(fid: int, ox: int, oz: int, heights: PackedFloat32Array) -> PackedVector3Array:
	var stride := TILE + 1
	var pos := PackedVector3Array()
	pos.resize(stride * stride)
	for i in range(stride * stride):
		var gi := i % stride
		var gj := i / stride
		var g := int(heights[i])
		var w := _lattice_world(fid, float(ox + gi), float(g), float(oz + gj))
		pos[i] = w - w.normalized() * SINK        # SEAMLESS-SCALES §5.1: strictly below the true surface
	return pos

## Gate surface (G-SKIN-EDGE): the raw sunk (stride×stride) positions a tile at lattice origin (ox,oz)
## would build. Takes the origin directly (not tx/tz) so the gate can FALSIFY by perturbing it.
func gate_tile_positions(fid: int, ox: int, oz: int) -> PackedVector3Array:
	var stride := TILE + 1
	var packed := PackedInt64Array()
	packed.resize(stride * stride)
	var k := 0
	for gj in range(stride):
		for gi in range(stride):
			packed[k] = _pack_xz(ox + gi, oz + gj)
			k += 1
	var res: Dictionary = _sampler.call(fid, packed)
	return _positions_from(fid, ox, oz, res["heights"])

static func _accum_normal(nrm: PackedVector3Array, pos: PackedVector3Array, a: int, b: int, c: int) -> void:
	var fn := (pos[b] - pos[a]).cross(pos[c] - pos[a])
	nrm[a] += fn; nrm[b] += fn; nrm[c] += fn

# --- coordinate helpers --------------------------------------------------------------------------

## Absolute planet-coord world point of lattice (fid,x,y,z) as a Vector3 (f32 render coord). The f64
## lattice_to_world64 is the exact placement map the near voxels and far ring use, so the skin lands on
## the same surface they do.
static func _lattice_world(fid: int, x: float, y: float, z: float) -> Vector3:
	var w := FacetAtlas.lattice_to_world64(fid, x, y, z)
	return Vector3(w[0], w[1], w[2])

## Pack a lattice column (x,z) into the int64 sample_columns expects: x low 32 bits, z high 32.
static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

func _key(fid: int, tx: int, tz: int) -> String:
	return "%d:%d:%d" % [fid, tx, tz]

## Build the compiled generator frozen for `active_fid`, exactly as module_world/verify_cppgen do (noise
## stack + material tables + frozen atlas + the §7.2 far_colors). Null if the class is not in the binary.
static func _build_cpp_gen(active_fid: int) -> Object:
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		return null
	var gen: Object = ClassDB.instantiate("VoxelGeneratorCosmos")
	if gen == null:
		return null
	var ns := TerrainConfig.noise_stack()
	var cfg := {
		"hills": ns["hills"], "detail": ns["detail"], "continent": ns["continent"],
		"temperature": ns["temperature"], "humidity": ns["humidity"], "mountain": ns["mountain"],
		"seed": ns["seed"], "gen_face": 0, "gen_n": 0, "gen_facet": active_fid,
		"flat_world": true, "faceted": CubeSphere.FACETED, "m5c_corner": CubeSphere.M5C_CORNER,
		"cube_arid": PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7]),
		"block_ids": TerrainConfig.appearance_surface_materials(), "model_count": 8, "waterlog": false,
		"id_wood": BlockCatalog.WOOD, "id_leaf": BlockCatalog.LEAF,
		"id_spruce_log": BlockCatalog.id_of(&"spruce_log"), "id_spruce_leaf": BlockCatalog.id_of(&"spruce_leaves"),
		"id_birch_log": BlockCatalog.id_of(&"birch_log"), "id_birch_leaf": BlockCatalog.id_of(&"birch_leaves"),
		"far_colors": FarPalette.frozen_colors(),
	}
	for k in TerrainConfig.material_tables():
		cfg[k] = TerrainConfig.material_tables()[k]
	if CubeSphere.FACETED:
		var atlas := FacetAtlas.frozen_atlas()
		cfg["facet_frame"] = atlas["facet_frame"]
		cfg["facet_off"] = atlas["facet_off"]
		cfg["facet_r_blocks"] = atlas["facet_r_blocks"]
	if not gen.call("setup", cfg):
		return null
	return gen

## The GDScript oracle sampler: the SAME core the C++ path mirrors (byte-equal by G-CG-COLUMNS), used only
## when the compiled class is absent. Returns the §7.2 key set for the packed (x,z) columns of facet `fid`.
static func gd_sample(fid: int, packed: PackedInt64Array) -> Dictionary:
	var n := packed.size()
	var heights := PackedFloat32Array(); heights.resize(n)
	var biomes := PackedInt32Array(); biomes.resize(n)
	var water := PackedByteArray(); water.resize(n)
	var colors := PackedColorArray(); colors.resize(n)
	var ctx = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else {}
	for i in range(n):
		var pk: int = packed[i]
		var vx := pk & 0xffffffff
		var x := (vx - 0x100000000) if vx >= 0x80000000 else vx
		var vz := (pk >> 32) & 0xffffffff
		var z := (vz - 0x100000000) if vz >= 0x80000000 else vz
		var pr: Vector4 = TerrainConfig.column_profile(x, z, ctx)
		var g := int(pr.x)
		var biome := int(pr.y)
		var w := g < TerrainConfig.SEA_LEVEL
		heights[i] = float(g)
		biomes[i] = biome
		water[i] = 1 if w else 0
		colors[i] = FarPalette.color_for(g, biome, pr.w, w)
	return {"heights": heights, "biomes": biomes, "water": water, "colors": colors}

func _make_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # winding-agnostic (facet transforms may flip)
	m.roughness = 1.0
	return m

# --- gate surface --------------------------------------------------------------------------------

## The ABSOLUTE-coord SUNK vertex the skin renders for column (fid,x,z). The gate asserts adjacent tiles
## agree here bit-for-bit (shared-edge) and that it sits SINK below the true surface (sink gate).
func skin_vertex(fid: int, x: int, z: int) -> Vector3:
	var res: Dictionary = _sampler.call(fid, PackedInt64Array([_pack_xz(x, z)]))
	var g := int((res["heights"] as PackedFloat32Array)[0])
	var w := _lattice_world(fid, float(x), float(g), float(z))
	return w - w.normalized() * SINK

## The TRUE (unsunk) absolute surface point for column (fid,x,z) — the sink gate's reference.
func true_vertex(fid: int, x: int, z: int) -> Vector3:
	var res: Dictionary = _sampler.call(fid, PackedInt64Array([_pack_xz(x, z)]))
	var g := int((res["heights"] as PackedFloat32Array)[0])
	return _lattice_world(fid, float(x), float(g), float(z))

## Build a tile and register it exactly as update() would (used by the memory gate's scripted pan). No
## budget enforcement here — the gate asserts the ceiling holds under update()'s enforcement separately.
func gate_add_tile(fid: int, tx: int, tz: int) -> bool:
	var key := _key(fid, tx, tz)
	if _tiles.has(key):
		return true
	var m := _build_tile(fid, tx, tz)
	if m.is_empty():
		return false
	add_child(m["mi"])
	_tiles[key] = m
	_bytes += int(m["bytes"])
	return true

func total_bytes() -> int: return _bytes
func tile_count() -> int: return _tiles.size()
func has_tile(fid: int, tx: int, tz: int) -> bool: return _tiles.has(_key(fid, tx, tz))

## Gate/telemetry: the farthest built tile centre from world point `pw`, over ALL facets the skin covers
## (not just the active one) — the honest reach of the current skin under the byte ceiling.
func coverage_radius(pw: Vector3) -> float:
	var best := 0.0
	for key in _tiles.keys():
		var parts: PackedStringArray = key.split(":")
		var f := int(parts[0]); var tx := int(parts[1]); var tz := int(parts[2])
		var c := FacetAtlas.lattice_to_world64(f, float(tx * TILE + TILE / 2), 0.0, float(tz * TILE + TILE / 2))
		best = maxf(best, pw.distance_to(Vector3(c[0], c[1], c[2])))
	return best
