extends SceneTree
## Controlled bench for the far-structure bake cost (FP_STRUCT_GATE_MEMO A/B). Enumerates the GEN houses on the first
## Earth facet that carries any, then times StructDecimator.decimate on each house bbox using the SAME per-fid GenCtx
## the production sampler (WorldManager.structure_cell_at) reuses — so the has_village/house_info memo behaves exactly
## as live. Deterministic bboxes ⇒ running once with the flag off and once with it on is a clean A/B on the SAME work.

const SG = preload("res://src/world/structure_gen.gd")
const SGI = preload("res://src/world/struct_gen_index.gd")
const SD = preload("res://src/world/struct_decimator.gd")
const FA = preload("res://src/cosmos/facet_atlas.gd")
const TC = preload("res://src/world/terrain_config.gd")

var _ctx                                     # the single per-fid GenCtx (carries column_top + the gate memos)

func sample(fid: int, cell: Vector3i) -> int:
	# Mirrors WorldManager.structure_cell_at's no-overlay branch (the bake path — no edits in the bench).
	return maxi(0, SG.claim_at(cell.x, cell.y, cell.z, _ctx))

func _initialize() -> void:
	print("FP_STRUCT_GATE_MEMO = ", CubeSphere.FP_STRUCT_GATE_MEMO)
	FA.warm_up()
	TC.warm_up()
	BlockCatalog.ensure_ready()
	var idx = SGI.new()
	var earth_n := 6 * FA.K * FA.K
	var fid := -1
	var recs: Array = []
	for f in range(mini(earth_n, 4000)):
		var r: Array = idx.enumerate_facet(f)
		if not r.is_empty():
			fid = f; recs = r; break
	if fid < 0:
		print("NO HOUSES FOUND"); quit(1); return
	_ctx = TC.GenCtx.new(0, fid)
	var samp := Callable(self, "sample")
	var n := mini(recs.size(), 40)
	# warm column_top memo the way a live facet is already warm (isolate the gate-hash cost, not first-touch terrain)
	for i in range(n):
		var bmin0: Vector3i = recs[i]["bmin"]
		TC.column_top(bmin0.x, bmin0.z, _ctx)
	# Replicate the FULL FacetFarStructures._ensure_bake path per house and time each stage separately, so we see
	# whether the decimate memo (the fix) or bake_lattice / the lattice→world transform dominates the live st_bms.
	var t_dec := 0.0
	var t_bake := 0.0
	var t_world := 0.0
	var total_solid := 0
	var total_cells := 0
	var total_tris := 0
	for i in range(n):
		var rec: Dictionary = recs[i]
		var bmin: Vector3i = rec["bmin"]
		var bmax: Vector3i = rec["bmax"]
		var a := Time.get_ticks_usec()
		var dec: Dictionary = SD.decimate(fid, bmin, bmax, samp)
		var b := Time.get_ticks_usec()
		var lat: Dictionary = SD.bake_lattice(dec)
		var c := Time.get_ticks_usec()
		var lverts: PackedVector3Array = lat["verts"]
		var wv := PackedVector3Array(); wv.resize(lverts.size())
		for k in range(lverts.size()):
			var v := lverts[k]
			var w = FA.lattice_to_world64(fid, v.x, v.y, v.z)
			wv[k] = Vector3(float(w[0]), float(w[1]), float(w[2]))
		var e := Time.get_ticks_usec()
		t_dec += float(b - a) * 0.001
		t_bake += float(c - b) * 0.001
		t_world += float(e - c) * 0.001
		total_solid += int(dec["solid_cells"])
		total_tris += int(lat["tris"])
		total_cells += (bmax.x - bmin.x + 1) * (bmax.y - bmin.y + 1) * (bmax.z - bmin.z + 1)
	# MERGE cost (the REAL rebuild hitch): the bakes are CACHED in production (_baked dict), so a rebuild only
	# CONCATENATES the cached per-house arrays + add_surface_from_arrays. Pre-bake to cache, then time ONLY concat+commit.
	var cached_v := []
	var cached_c := []
	for i in range(n):
		var rec: Dictionary = recs[i]
		var lat: Dictionary = SD.bake_lattice(SD.decimate(fid, rec["bmin"], rec["bmax"], samp))
		cached_v.append(lat["verts"]); cached_c.append(lat["colors"])
	# time the rebuild: concat + add_surface (repeat x5 for a stable read — this fires EVERY membership change live)
	var t_merge := 0.0
	for _rep in range(5):
		var mverts := PackedVector3Array(); var mcolors := PackedColorArray()
		var m0 := Time.get_ticks_usec()
		for i in range(n):
			mverts.append_array(cached_v[i]); mcolors.append_array(cached_c[i])
		var mesh := ArrayMesh.new()
		if not mverts.is_empty():
			var arr := []; arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = mverts; arr[Mesh.ARRAY_COLOR] = mcolors
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		t_merge += float(Time.get_ticks_usec() - m0) * 0.001
	t_merge /= 5.0
	var mvcount := 0
	for a in cached_v: mvcount += a.size()
	print("STRUCT_TARGET_RES=", CubeSphere.STRUCT_TARGET_RES, "  merged_verts=", mvcount, " REBUILD(concat+commit)=", snappedf(t_merge, 2), " ms  (x", n, " houses; live scales to the 80k-tri cap)")
	var tot := t_dec + t_bake + t_world
	print("fid=", fid, " houses=", n, " cells=", total_cells, " solid=", total_solid, " tris=", total_tris)
	print("_ensure_bake TOTAL ", snappedf(tot, 1), " ms  (", snappedf(tot / float(n), 2), " /house)")
	print("  decimate    ", snappedf(t_dec, 1), " ms  (", snappedf(t_dec / float(n), 2), " /house)  <<< the memo target")
	print("  bake_lattice", snappedf(t_bake, 1), " ms  (", snappedf(t_bake / float(n), 2), " /house)")
	print("  lat->world  ", snappedf(t_world, 1), " ms  (", snappedf(t_world / float(n), 2), " /house)")
	quit(0)
