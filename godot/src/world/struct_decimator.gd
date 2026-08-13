class_name StructDecimator
extends RefCounted
## COSMOS STRUCTURES P0 (docs/COSMOS-STRUCTURES-DESIGN.md §6) — the decimated far-model bake. PURE static
## arithmetic (no Node, no rendering, no WorldManager access): a `sampler` Callable(fid, Vector3i) -> block_id
## (0 = air) supplies the structure's cells, and the output is a coarse OR-occupancy grid + one majority-colour
## per solid coarse cell, then a face-culled cube ArrayMesh in the structure's OWN fid-lattice float coords.
##
## DECIMATION LAW (§6.1), adapted from FacetBlockLod's 2× downscale (facet_block_lod.gd:91-153) but DELIBERATELY
## INVERTED on occupancy:
##  - Coarse pitch `c = max(1, 2^ceil(log2(max_extent / STRUCT_TARGET_RES)))` — a small house bakes at c=1 (it IS
##    its own model), a mega-build coarsens automatically.
##  - Occupancy = OR of the c³ children (any solid child ⇒ coarse solid). MIN (FacetBlockLod's terrain-containment
##    rule) would delete 1-block walls/roofs = exactly the silhouette; OR dilates by ≤ one coarse cell, and the
##    far-over-near protrusion is enforced by the handoff cull + band gate, not the model shape (§6.1).
##  - Colour = MAJORITY block id among the solid children, ties → smallest id — the `_majority_id` law verbatim
##    (facet_block_lod.gd:140-153) — coloured via BlockCatalog.color_of so far models match near blocks by construction.
##  - Deterministic: same sampler ⇒ byte-identical grid (the gate re-derives + compares).
##
## Because the sampler reads the PLACED overlay (WorldManager.structure_cell_at), a player-damaged build (a dug wall
## cell reads air) decimates DAMAGED for free — no special path (§6.1 / design rule 3).

## Coarse pitch for a structure of the given max extent (blocks). Power-of-two so nested levels (P2 LOD-B = c×2) align.
static func coarse_pitch(max_extent: int) -> int:
	if max_extent <= CubeSphere.STRUCT_TARGET_RES:
		return 1
	var ratio := float(max_extent) / float(CubeSphere.STRUCT_TARGET_RES)
	var e := int(ceil(log(ratio) / log(2.0)))
	return maxi(1, 1 << e)


## Decimate the structure in bbox [bmin, bmax] (inclusive, fid-lattice cells) to a coarse occupancy grid + majority
## colour id per solid coarse cell. Returns {c, cw, ch, cd, bmin, occ:PackedByteArray, mid:PackedInt32Array,
## solid_cells}. `occ`/`mid` are index-parallel in (cx + cy*cw + cz*cw*ch) order. `pitch` override lets P2 bake LOD-B.
static func decimate(fid: int, bmin: Vector3i, bmax: Vector3i, sampler: Callable, pitch := 0) -> Dictionary:
	var dx := bmax.x - bmin.x + 1
	var dy := bmax.y - bmin.y + 1
	var dz := bmax.z - bmin.z + 1
	var max_extent := maxi(maxi(dx, dy), dz)
	var c := pitch if pitch > 0 else coarse_pitch(max_extent)
	var cw := (dx + c - 1) / c
	var ch := (dy + c - 1) / c
	var cd := (dz + c - 1) / c
	var n := cw * ch * cd
	var occ := PackedByteArray(); occ.resize(n); occ.fill(0)
	var mid := PackedInt32Array(); mid.resize(n); mid.fill(0)
	var solid_cells := 0
	for cz in range(cd):
		for cy in range(ch):
			for cx in range(cw):
				var counts := {}                       # id → vote count among the solid children
				var any := false
				var x0 := bmin.x + cx * c
				var y0 := bmin.y + cy * c
				var z0 := bmin.z + cz * c
				for lz in range(c):
					var wz := z0 + lz
					if wz > bmax.z: break
					for ly in range(c):
						var wy := y0 + ly
						if wy > bmax.y: break
						for lx in range(c):
							var wx := x0 + lx
							if wx > bmax.x: break
							var id := int(sampler.call(fid, Vector3i(wx, wy, wz)))
							if id > 0:
								any = true
								counts[id] = int(counts.get(id, 0)) + 1
				if any:
					var i := cx + cy * cw + cz * cw * ch
					occ[i] = 1
					mid[i] = _majority_id(counts)
					solid_cells += 1
	return {"c": c, "cw": cw, "ch": ch, "cd": cd, "bmin": bmin, "occ": occ, "mid": mid, "solid_cells": solid_cells}


## MAJORITY id among solid children; ties → SMALLEST id (deterministic, order-independent). Verbatim FacetBlockLod law.
static func _majority_id(counts: Dictionary) -> int:
	var best_id := 0x7fffffff
	var best_ct := -1
	for id in counts:
		var ct: int = int(counts[id])
		if ct > best_ct or (ct == best_ct and int(id) < best_id):
			best_ct = ct
			best_id = int(id)
	return best_id if best_ct >= 0 else 0


## Bake the decimated grid into a face-culled cube ArrayMesh in the structure's OWN fid-lattice float coords (the
## FacetFarStructures tier maps each vertex lattice→world64 and merges it into the ONE band mesh). Only faces adjacent
## to an empty coarse cell are emitted (interior faces culled). Per-vertex COLOR = BlockCatalog.color_of(majority id).
## Returns {verts:PackedVector3Array, colors:PackedColorArray, tris:int}. Empty ⇒ zero-length arrays (no surface).
static func bake_lattice(dec: Dictionary) -> Dictionary:
	var c: int = dec["c"]
	var cw: int = dec["cw"]; var ch: int = dec["ch"]; var cd: int = dec["cd"]
	var bmin: Vector3i = dec["bmin"]
	var occ: PackedByteArray = dec["occ"]
	var mid: PackedInt32Array = dec["mid"]
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var faces := 0
	# +X,-X,+Y,-Y,+Z,-Z neighbour tests + the 4 CCW corners of each face (in coarse-cell units of size c).
	for cz in range(cd):
		for cy in range(ch):
			for cx in range(cw):
				var i := cx + cy * cw + cz * cw * ch
				if occ[i] == 0:
					continue
				var col := BlockCatalog.color_of(mid[i]); col.a = 1.0
				# lattice-space min corner of this coarse cube
				var x0 := float(bmin.x + cx * c)
				var y0 := float(bmin.y + cy * c)
				var z0 := float(bmin.z + cz * c)
				var s := float(c)
				# For each of the 6 faces: emit iff the neighbour coarse cell is empty (or out of grid).
				if not _solid(occ, cw, ch, cd, cx + 1, cy, cz):
					_quad(verts, colors, col, Vector3(x0 + s, y0, z0), Vector3(x0 + s, y0 + s, z0), Vector3(x0 + s, y0 + s, z0 + s), Vector3(x0 + s, y0, z0 + s)); faces += 1
				if not _solid(occ, cw, ch, cd, cx - 1, cy, cz):
					_quad(verts, colors, col, Vector3(x0, y0, z0 + s), Vector3(x0, y0 + s, z0 + s), Vector3(x0, y0 + s, z0), Vector3(x0, y0, z0)); faces += 1
				if not _solid(occ, cw, ch, cd, cx, cy + 1, cz):
					_quad(verts, colors, col, Vector3(x0, y0 + s, z0), Vector3(x0, y0 + s, z0 + s), Vector3(x0 + s, y0 + s, z0 + s), Vector3(x0 + s, y0 + s, z0)); faces += 1
				if not _solid(occ, cw, ch, cd, cx, cy - 1, cz):
					_quad(verts, colors, col, Vector3(x0, y0, z0 + s), Vector3(x0, y0, z0), Vector3(x0 + s, y0, z0), Vector3(x0 + s, y0, z0 + s)); faces += 1
				if not _solid(occ, cw, ch, cd, cx, cy, cz + 1):
					_quad(verts, colors, col, Vector3(x0, y0, z0 + s), Vector3(x0 + s, y0, z0 + s), Vector3(x0 + s, y0 + s, z0 + s), Vector3(x0, y0 + s, z0 + s)); faces += 1
				if not _solid(occ, cw, ch, cd, cx, cy, cz - 1):
					_quad(verts, colors, col, Vector3(x0, y0 + s, z0), Vector3(x0 + s, y0 + s, z0), Vector3(x0 + s, y0, z0), Vector3(x0, y0, z0)); faces += 1
	return {"verts": verts, "colors": colors, "tris": faces * 2}


static func _solid(occ: PackedByteArray, cw: int, ch: int, cd: int, cx: int, cy: int, cz: int) -> bool:
	if cx < 0 or cy < 0 or cz < 0 or cx >= cw or cy >= ch or cz >= cd:
		return false
	return occ[cx + cy * cw + cz * cw * ch] != 0


## One quad (2 tris, 6 verts, CCW so the front face points outward) with a flat per-vertex colour.
static func _quad(verts: PackedVector3Array, colors: PackedColorArray, col: Color, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	verts.push_back(a); verts.push_back(b); verts.push_back(c)
	verts.push_back(a); verts.push_back(c); verts.push_back(d)
	for _k in range(6):
		colors.push_back(col)
