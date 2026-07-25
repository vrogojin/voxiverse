class_name FacetBlockLod
extends RefCounted
## COSMOS BLOCK-LOD P0 (docs/COSMOS-BLOCK-LOD-DESIGN.md §2/§3/§9) — the per-facet DECIMATED-BLOCK column pyramid + its
## 2× downscale decimator. PURE DATA + arithmetic (no Node, no rendering, no streaming) — the headless-provable
## foundation the later render phases (P1+) build on. Mirrors FacetFarRing's sampling discipline: absolute planet
## terrain read through the ONE analytic profile sampler (TerrainConfig.facet_profile — the (fid,x,z) integer lattice
## the one-map rule pins to profile_at_dir(cell_dir)), water classified from the SAME source the far ring uses
## (g < SEA_LEVEL). NO real-voxel / _edits bake in P0 (that is P4, FP_BLOCK_LOD_REALBAKE).
##
## Data model (§2): level Ln has pitch 2^n blocks (L0 = full-res, 1 block). A level is a rectangular COLUMN grid over
## the facet's integer lattice domain [dom_min .. dom_max] (the true (fid,x,z) lattice incl. the 8-cell streaming
## margin, ≈ the design's edge×edge ≈417² grid); each level halves (round up). Each column stores {top_h, id, water}
## as three index-parallel packed arrays (the simplest representation the gate can read):
##   top : PackedInt32Array  — surface top height (blocks; i16 range, stored int32 for headroom)
##   id  : PackedByteArray    — surface classifier id 0..255 (the biome id from facet_profile.y — the SAME per-column
##                             classifier the far ring feeds FarPalette; the BlockCatalog surface-block mapping is a
##                             render concern deferred to P1)
##   water : PackedByteArray  — 1 iff the column reads as water (g < SEA_LEVEL), else 0
##
## 2× downscale rule (§3), EXACT — no-protrusion by containment:
##   top(coarse)   = MIN(top of the present 2×2 fine children)   ⇒ coarse solid ⊆ space below the fine surface
##   id(coarse)    = MAJORITY of children whose top is within ONE COARSE PITCH (2^coarse_level) of the coarse top;
##                   ties broken by SMALLEST id (deterministic). The min-top child always qualifies.
##   water(coarse) = OR of the present children's water
## Partial 2×2 at the facet boundary: decimate over the PRESENT children only (still MIN / MAJORITY / OR).
##
## Pyramid invariant (G-BLD-PYR): Ln+1 == decimate(Ln) exactly — build L0 analytically, then L1..L5 each by
## decimate(previous). Deterministic (facet_profile + decimate are pure) ⇒ headless-provable, byte-reproducible.
##
## NEVER-OOM: NO always-resident store (that is P3 global). One facet's pyramid is transient — build, read, drop the
## reference (RefCounted auto-frees). The gate builds, asserts, and releases each facet in turn.

const LEVELS := 6                 # L0..L5 (design ladder §4; pitch 1,2,4,8,16,32)
const ID_MAX := 255               # surface-id clamp (fits PackedByteArray)

var fid := -1
# levels[n] = { "n":int, "w":int, "h":int, "top":PackedInt32Array, "id":PackedByteArray, "water":PackedByteArray }
var levels: Array = []


## Build the full L0..L5 pyramid for `target_fid`: L0 analytically from facet_profile, then each coarser level by
## decimating the one below. Requires FacetAtlas.warm_up() (populates the lattice domain + frame). Idempotent.
func build(target_fid: int) -> void:
	fid = target_fid
	levels.clear()
	levels.append(_bake_l0(target_fid))
	for n in range(1, LEVELS):
		levels.append(decimate(levels[n - 1]))


func level_count() -> int:
	return levels.size()


func get_level(n: int) -> Dictionary:
	return levels[n]


## L0: the full-resolution column grid over the facet's integer lattice domain. One facet_profile per column
## (the (fid,x,z) lattice sampler; deterministic in (SEED, fid, x, z)). top = g, id = biome (clamped 0..255),
## water = g < SEA_LEVEL (STRICT, matching FacetFarRing's near-sea classifier).
static func _bake_l0(target_fid: int) -> Dictionary:
	var dmin := FacetAtlas.dom_min(target_fid)
	var dmax := FacetAtlas.dom_max(target_fid)
	var w := dmax.x - dmin.x + 1
	var h := dmax.y - dmin.y + 1
	var top := PackedInt32Array()
	var idb := PackedByteArray()
	var wat := PackedByteArray()
	var count := w * h
	top.resize(count)
	idb.resize(count)
	wat.resize(count)
	var i := 0
	for lz in range(h):
		var z := dmin.y + lz
		for lx in range(w):
			var x := dmin.x + lx
			var prof := TerrainConfig.facet_profile(target_fid, x, z)
			var g := int(prof.x)
			top[i] = g
			idb[i] = clampi(int(prof.y), 0, ID_MAX)
			wat[i] = 1 if g < TerrainConfig.SEA_LEVEL else 0
			i += 1
	return {"n": 0, "w": w, "h": h, "top": top, "id": idb, "water": wat}


## The 2× downscale (§3): coarse level = fine.n + 1, dims = ceil(w/2) × ceil(h/2). PURE + static so the gate can
## re-derive any level from the one below (G-BLD-PYR) with no build-order dependency. MIN top / MAJORITY id / OR water
## over the present 2×2 children (odd edge / boundary ⇒ fewer than 4 children, still exact).
static func decimate(fine: Dictionary) -> Dictionary:
	var fw: int = fine["w"]
	var fh: int = fine["h"]
	var ftop: PackedInt32Array = fine["top"]
	var fidr: PackedByteArray = fine["id"]
	var fwat: PackedByteArray = fine["water"]
	var cn: int = int(fine["n"]) + 1
	var cw := (fw + 1) >> 1
	var ch := (fh + 1) >> 1
	var coarse_pitch := 1 << cn                # the "1 coarse pitch" id-vote band (blocks)
	var top := PackedInt32Array()
	var idb := PackedByteArray()
	var wat := PackedByteArray()
	var count := cw * ch
	top.resize(count)
	idb.resize(count)
	wat.resize(count)
	for cz in range(ch):
		for cx in range(cw):
			var ci := cz * cw + cx
			var tmin := 0x7fffffff
			var wor := 0
			# present 2×2 children (deterministic dz,dx order) — [top, id] pairs.
			var kids: Array = []
			for dz in range(2):
				var fz := (cz << 1) + dz
				if fz >= fh:
					continue
				var rowoff := fz * fw
				for dx in range(2):
					var fx := (cx << 1) + dx
					if fx >= fw:
						continue
					var fi := rowoff + fx
					var ct: int = ftop[fi]
					kids.append([ct, int(fidr[fi])])
					if ct < tmin:
						tmin = ct
					if fwat[fi] != 0:
						wor = 1
			top[ci] = tmin
			wat[ci] = wor
			idb[ci] = _majority_id(kids, tmin, coarse_pitch)
	return {"n": cn, "w": cw, "h": ch, "top": top, "id": idb, "water": wat}


## MAJORITY id among children whose top is within `band` blocks of the coarse (MIN) top `tmin` — a deep pit never
## recolours a hilltop. Ties → smallest id (fixed ascending order ⇒ deterministic irrespective of vote-map order).
## The min-top child (top == tmin) always qualifies, so `kids` non-empty ⇒ a vote always exists.
static func _majority_id(kids: Array, tmin: int, band: int) -> int:
	var counts := {}                           # id -> vote count
	for k in kids:
		if int(k[0]) - tmin <= band:
			var kid: int = int(k[1])
			counts[kid] = int(counts.get(kid, 0)) + 1
	var best_id := ID_MAX + 1
	var best_ct := -1
	for kid in counts:
		var c: int = int(counts[kid])
		if c > best_ct or (c == best_ct and kid < best_id):
			best_ct = c
			best_id = kid
	return best_id if best_id <= ID_MAX else 0


## Bit-equality of two level dicts (n,w,h + the three packed arrays). Used by G-BLD-PYR / G-BLD-DETERMINISM.
static func level_equals(a: Dictionary, b: Dictionary) -> bool:
	if int(a["n"]) != int(b["n"]) or int(a["w"]) != int(b["w"]) or int(a["h"]) != int(b["h"]):
		return false
	return a["top"] == b["top"] and a["id"] == b["id"] and a["water"] == b["water"]
