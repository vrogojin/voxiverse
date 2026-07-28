class_name FacetBlockLodRing
extends Node3D
## COSMOS BLOCK-LOD P1 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4 + docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §4 override) —
## the FIRST visible decimated-block ring: ONE L1 (2-block pitch) megablock tier engaging at the near rim
## (~128 blocks) and covering the active facet + its 4 ridge neighbours (out to ~700), rendered as REAL greedy-
## meshed extruded blocky geometry OVER the far-ring skin. Closes the near→far RELIEF gap that S1 leaves: climbing
## out of the near voxel field steps 1-block → 2-block pitch (a ≤1-block containment step) instead of the current
## 3D-blocks → flat-paint cliff. This is the block-LOD design's P1, with Fable's §4 override — L1 at the rim, NOT
## L2 at 700 (the transition goal needs the rim ring). The full L2–L4 ladder is P2 (FP_BLOCK_LOD_RINGS), NOT here.
##
## SIBLING of FacetFarRing / FacetSkinTier under WorldManager — GATED CONSTRUCTION: the node/data only exist when
## FP_BLOCK_LOD is on ⇒ byte-identical off (WorldManager never news it up; nothing calls it). Mirrors the far ring's
## discipline: absolute planet coords, per-facet meshes, placed by the SAME node transform the far ring uses (so the
## L1 blocks and the far skin share ONE frame), rebuilt on facet crossings (band = active ∪ ridge-1).
##
## DATA: the P0 FacetBlockLod column pyramid (facet_block_lod.gd) — analytic L0 via TerrainConfig.facet_profile, then
## L1 = decimate(L0) with the §3 MIN-height / MAJORITY-id / OR-water 2× downscale (no-protrusion by containment:
## rendered coarse ≤ true fine terrain everywhere ⇒ never protrudes, structurally improves #72). Real-voxel / _edits
## bake is P4 (FP_BLOCK_LOD_REALBAKE) per design §9 — P1 is analytic, matching the far ring's one-sampler law.
##
## MESHING (§4): per facet, greedy-merged extruded L1 columns — top quads merged across equal-height/equal-id runs
## (ocean/plains → a few quads), interior side quads where a lattice neighbour is lower (corners from the shared
## integer (fid,x,z) lattice via FacetAtlas.lattice_to_world64 ⇒ adjacent columns weld BIT-IDENTICALLY), + a boundary
## SKIRT dropped one coarse pitch on the facet-polygon perimeter (closes the silhouette gap to the sunk backstop). ONE
## MeshInstance/ArrayMesh per facet ⇒ draws ≈ band facets (≤5) ≪ columns (~40k). Vertex-coloured from FarPalette (the
## SAME palette the far ring feeds), UNSHADED, composing with the shell `shade·tint` law (radial normal = normalize(
## wp − MODEL·0)); under FP_SHADE_UNIFIED it string-includes VoxiLight.SHADE_GLSL so L1 lights IDENTICALLY to the near
## blocks AND the far skin (one light law). Arrival DITHER only (§4 temporal): a 0.3 s screen-door discard fade on a
## facet mesh's arrival — NOT a standing spatial band; no transparency/sorting.
##
## COMPOSITION (§6): L1 emits OVER the far-ring skin (the far ring stays as the sunk always-there backstop
## underneath). With S1 (FP_APPROACH_ANCHOR) also on, the near plate recedes into L1 blocks instead of flat paint.
## NOTE (follow-up, NOT this task): S1's release distance should later tighten to the L1 engagement distance
## (BLOCK_LOD_L1_RIM_BLOCKS) so the near plate hands directly to the L1 rim.
##
## NEVER-OOM (§5): a hard ledger BLOCK_LOD_BYTES_MAX (16 MB), an LRU cap on resident L1 facet meshes, wholesale-clear
## on breach, and the L1 band bounded to the active facet + ridge-1 neighbours. The gate (verify_block_lod.gd) asserts
## the measured ledger == arithmetic, LRU never evicts the active band, draws ≈ facets, and the no-protrusion + weld
## laws (G-BLD-MIN / G-BLD-PYR / G-BLD-SEAM / G-BLD-BYTES / G-BLD-DRAWS).

const LEVEL := 1                       # P1: the L1 (2-block pitch) tier — the rim ring (Fable §4 override)
const PITCH := 1 << LEVEL              # 2 blocks per L1 megablock

# Per-vertex ArrayMesh cost (no NORMAL array — the unshaded shader derives the radial normal): position(12) +
# color(16) + uv(8) = 36 B/vertex; indices are int32 (4 B). The ledger below sums exactly this.
const BYTES_PER_VERT := 36
const BYTES_PER_INDEX := 4

var _active_fid := -1
var _mesh_by_fid: Dictionary = {}      # fid -> MeshInstance3D (one draw per resident facet)
var _bytes_by_fid: Dictionary = {}     # fid -> int (arithmetic mesh bytes; summed into _ledger_bytes)
var _lru: Dictionary = {}              # fid -> last-touched ms (LRU eviction key; band fids never evicted)
var _ledger_bytes := 0                 # Σ _bytes_by_fid — the NEVER-OOM ledger (≤ BLOCK_LOD_BYTES_MAX)
var _material: ShaderMaterial = null
var _sun_dir := Vector3(1.0, 0.0, 0.0)
var _wholesale_clears := 0             # diagnostics: ledger-breach wholesale clears (gate reads to prove it fired)


func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_material = _make_material()
	set_process(true)
	rebuild(active_fid)


## The L1 band for `active_fid`: the active facet ∪ its 4 ridge (seam) neighbours. Bounded (§5/§7) so the streamed
## set is O(1) per crossing. Deterministic order (active first) so the active facet is always the protected member.
func band_fids(active_fid: int) -> Array:
	var out: Array = [active_fid]
	for slot in range(4):
		var nb := FacetAtlas.seam_neighbour(active_fid, slot)
		if nb >= 0 and not out.has(nb):
			out.append(nb)
	return out


## Re-place + re-stream the band for a (possibly new) active facet. Called on setup and on every crossing. Builds any
## band facet not yet resident, touches the LRU of the whole band, then evicts down to the cap / ledger (never the
## band). O(band) builds per crossing; a facet already resident is a pure LRU touch (no rebuild — the far-ring cache
## discipline). Placement (the node transform) is mirrored from the far ring by WorldManager via place().
func rebuild(active_fid: int) -> void:
	_active_fid = active_fid
	var band := band_fids(active_fid)
	var now := Time.get_ticks_msec()
	for fid in band:
		if not _mesh_by_fid.has(fid):
			_build_facet(fid)
		_lru[fid] = now
	_enforce_budget(band)


## Set the render placement (absolute planet coords → current render frame). Mirrors the far ring's own node
## transform so the L1 blocks and the far skin sit in ONE frame (they overlap by construction — L1 overdraws the sunk
## backstop). WorldManager passes _facet_ring.transform each frame.
func place(xform: Transform3D) -> void:
	transform = xform


## Forward the Sun direction into the shared material (same value the far-ring shell gets), so the day/night
## shade·tint matches the far skin and the near blocks exactly.
func set_sun_dir(sun_dir: Vector3) -> void:
	_sun_dir = sun_dir
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)


func _process(_delta: float) -> void:
	# Feed the arrival-dither clock (§4 temporal): each facet mesh carries its build time in UV.x; the fragment
	# screen-door-discards until (now − arrival) exceeds BLOCK_LOD_DITHER_S. One uniform write/frame.
	if _material != null:
		_material.set_shader_parameter("u_now", float(Time.get_ticks_msec()) / 1000.0)


# ---- ledger / LRU (NEVER-OOM §5) -------------------------------------------------------------------------------

func ledger_bytes() -> int:
	return _ledger_bytes

func facet_bytes(fid: int) -> int:
	return int(_bytes_by_fid.get(fid, 0))

func resident_fids() -> Array:
	return _mesh_by_fid.keys()

## Draw count == resident non-empty facet meshes (one draw each). The gate asserts this is ≈ band facets ≪ columns.
func draw_count() -> int:
	var n := 0
	for fid in _mesh_by_fid:
		var mi: MeshInstance3D = _mesh_by_fid[fid]
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			n += 1
	return n

func wholesale_clears() -> int:
	return _wholesale_clears


## Evict resident facets outside `band`, LRU-first, until BOTH the LRU-facet cap AND the byte ledger are satisfied.
## The band is NEVER evicted (the active set is protected — G-BLD-BYTES). If the ledger is still breached after all
## non-band facets are gone, wholesale-clear everything non-band (already done) — the band alone is bounded (≤5 small
## facets) and is the irreducible floor.
func _enforce_budget(band: Array) -> void:
	# 1) LRU cap on resident facets.
	while _mesh_by_fid.size() > CubeSphere.BLOCK_LOD_LRU_FACETS:
		var victim := _lru_victim(band)
		if victim < 0:
			break
		_evict(victim)
	# 2) Byte ledger.
	if _ledger_bytes <= CubeSphere.BLOCK_LOD_BYTES_MAX:
		return
	while _ledger_bytes > CubeSphere.BLOCK_LOD_BYTES_MAX:
		var victim := _lru_victim(band)
		if victim < 0:
			break                                  # only the band remains — the bounded floor
		_evict(victim)
	# 3) Wholesale-clear guard: if a single band build overran the ceiling, drop every non-band facet in one sweep
	#    (already achieved above); record the breach so the gate can see the safety fired.
	if _ledger_bytes > CubeSphere.BLOCK_LOD_BYTES_MAX:
		_wholesale_clears += 1


func _lru_victim(band: Array) -> int:
	var best := -1
	var best_ms := 0x7fffffffffffffff
	for fid in _mesh_by_fid:
		if band.has(fid):
			continue
		var ms := int(_lru.get(fid, 0))
		if ms < best_ms:
			best_ms = ms
			best = fid
	return best


func _evict(fid: int) -> void:
	var mi: MeshInstance3D = _mesh_by_fid.get(fid, null)
	if mi != null:
		remove_child(mi)
		mi.queue_free()
	_mesh_by_fid.erase(fid)
	_ledger_bytes -= int(_bytes_by_fid.get(fid, 0))
	_bytes_by_fid.erase(fid)
	_lru.erase(fid)


# ---- meshing (§4) ----------------------------------------------------------------------------------------------

func _build_facet(fid: int) -> void:
	var arr := _build_facet_arrays(fid)
	var verts: PackedVector3Array = arr["verts"]
	if verts.is_empty():
		return
	var am := ArrayMesh.new()
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_COLOR] = arr["colors"]
	a[Mesh.ARRAY_TEX_UV] = arr["uvs"]
	a[Mesh.ARRAY_INDEX] = arr["indices"]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var mi := MeshInstance3D.new()
	mi.name = "BlockLodL1_%d" % fid
	mi.mesh = am
	mi.material_override = _material
	# The mesh is absolute planet coords; the far ring's fog/shading governs beyond — no cast shadow (unshaded tier).
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_mesh_by_fid[fid] = mi
	var bytes: int = int(arr["bytes"])
	_bytes_by_fid[fid] = bytes
	_ledger_bytes += bytes


## Greedy-mesh facet `fid`'s L1 tier into absolute-coord arrays. Pure w.r.t. the RenderingServer (a gate can call it
## directly). Returns {verts, colors, uvs, indices, bytes, n_top, n_side, n_skirt, edges}. `edges` is the set of
## emitted vertical-edge keys (side + skirt) — the seam bookkeeping G-BLD-SEAM audits against the required set.
func _build_facet_arrays(fid: int) -> Dictionary:
	var lod := FacetBlockLod.new()
	lod.build(fid)
	var lvl := lod.get_level(LEVEL)
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var top: PackedInt32Array = lvl["top"]
	var idb: PackedByteArray = lvl["id"]
	var wat: PackedByteArray = lvl["water"]
	var dmin := FacetAtlas.dom_min(fid)
	var half := PITCH >> 1

	# Emitted mask + per-column colour (RGBA8-packed for greedy equality) + the Color itself.
	var emit := PackedByteArray(); emit.resize(w * h)
	var col32 := PackedInt32Array(); col32.resize(w * h)
	var cols: Array = []; cols.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			var lx := dmin.x + cx * PITCH + half      # representative L0 cell (coarse-cell centre)
			var lz := dmin.y + cz * PITCH + half
			if not FacetAtlas.in_polygon(fid, lx, lz, 0.0):
				emit[ci] = 0
				continue
			emit[ci] = 1
			# Temperature for the palette (snow-cap / frozen-or-lava sea) — sampled once per emitted coarse column,
			# the SAME profile the far ring reads. id/water come from the decimated pyramid (majority / OR).
			var t: float = TerrainConfig.facet_profile(fid, lx, lz).w
			var c := FarPalette.color_for(top[ci], int(idb[ci]), t, wat[ci] != 0)
			cols[ci] = c
			col32[ci] = _rgba8(c)

	var verts := PackedVector3Array()
	var vcol := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var arrival := float(Time.get_ticks_msec()) / 1000.0
	var edges := {}                                   # emitted vertical-edge keys (side + skirt)
	var n_top := 0
	var n_side := 0
	var n_skirt := 0

	# --- TOP faces: greedy-merge rectangular runs of equal (top-height, colour) over the emitted grid. -----------
	var used := PackedByteArray(); used.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0 or used[ci] != 0:
				continue
			var th := top[ci]
			var c32 := col32[ci]
			# extend width
			var rw := 1
			while cx + rw < w:
				var ni := cz * w + cx + rw
				if emit[ni] == 0 or used[ni] != 0 or top[ni] != th or col32[ni] != c32:
					break
				rw += 1
			# extend height (whole rows only)
			var rh := 1
			var grow := true
			while grow and cz + rh < h:
				for k in range(rw):
					var ni := (cz + rh) * w + cx + k
					if emit[ni] == 0 or used[ni] != 0 or top[ni] != th or col32[ni] != c32:
						grow = false
						break
				if grow:
					rh += 1
			for zz in range(rh):
				for xx in range(rw):
					used[(cz + zz) * w + cx + xx] = 1
			# quad corners on the shared integer lattice (bit-identical welds — G-SKIN-EDGE)
			var x0 := dmin.x + cx * PITCH
			var x1 := dmin.x + (cx + rw) * PITCH
			var z0 := dmin.y + cz * PITCH
			var z1 := dmin.y + (cz + rh) * PITCH
			var c: Color = cols[ci]
			_add_quad(verts, vcol, uvs, idx,
				_w(fid, x0, th, z0), _w(fid, x1, th, z0), _w(fid, x1, th, z1), _w(fid, x0, th, z1),
				c, arrival)
			n_top += 1

	# --- SIDE faces (interior height steps) + SKIRT (facet-polygon perimeter, dropped one coarse pitch). ---------
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0:
				continue
			var th := top[ci]
			var c: Color = cols[ci]
			for d: Vector2i in dirs:
				var nx := cx + d.x
				var nz := cz + d.y
				var nb_emit := false
				var nb_top := 0
				if nx >= 0 and nx < w and nz >= 0 and nz < h and emit[nz * w + nx] != 0:
					nb_emit = true
					nb_top = top[nz * w + nx]
				var y_lo := th
				var is_skirt := false
				if nb_emit:
					if nb_top >= th:
						continue                       # neighbour at-or-above covers this edge
					y_lo = nb_top                       # interior wall down to the shorter neighbour
				else:
					y_lo = th - PITCH                   # boundary skirt: drop one coarse pitch to the backstop
					is_skirt = true
				# shared-edge endpoints (integer lattice) + the canonical edge key
				var xa: int; var za: int; var xb: int; var zb: int; var key: String
				if d == Vector2i(1, 0):
					xa = dmin.x + (cx + 1) * PITCH; za = dmin.y + cz * PITCH
					xb = xa; zb = dmin.y + (cz + 1) * PITCH
					key = "x:%d:%d" % [cx + 1, cz]
				elif d == Vector2i(-1, 0):
					xa = dmin.x + cx * PITCH; za = dmin.y + cz * PITCH
					xb = xa; zb = dmin.y + (cz + 1) * PITCH
					key = "x:%d:%d" % [cx, cz]
				elif d == Vector2i(0, 1):
					xa = dmin.x + cx * PITCH; za = dmin.y + (cz + 1) * PITCH
					xb = dmin.x + (cx + 1) * PITCH; zb = za
					key = "z:%d:%d" % [cx, cz + 1]
				else:
					xa = dmin.x + cx * PITCH; za = dmin.y + cz * PITCH
					xb = dmin.x + (cx + 1) * PITCH; zb = za
					key = "z:%d:%d" % [cx, cz]
				_add_quad(verts, vcol, uvs, idx,
					_w(fid, xa, y_lo, za), _w(fid, xb, y_lo, zb), _w(fid, xb, th, zb), _w(fid, xa, th, za),
					c, arrival)
				edges[key] = true
				if is_skirt:
					n_skirt += 1
				else:
					n_side += 1

	var nv := verts.size()
	var nidx := idx.size()
	var bytes := nv * BYTES_PER_VERT + nidx * BYTES_PER_INDEX
	return {
		"verts": verts, "colors": vcol, "uvs": uvs, "indices": idx, "bytes": bytes,
		"n_top": n_top, "n_side": n_side, "n_skirt": n_skirt, "edges": edges,
		"w": w, "h": h,
	}


## Independent seam audit for `fid` (G-BLD-SEAM teeth): re-derive the REQUIRED set of vertical-edge keys (every
## emitted column edge that is either a height step to a lower emitted neighbour OR a facet-polygon boundary) and
## confirm the mesher emitted a quad (side or skirt) for EVERY one — i.e. no silhouette hole. Returns the number of
## missing edges (0 = watertight boundary). Recomputed from the pyramid, NOT read back from the mesh, so a mesher
## that skipped a boundary/step edge would leave a required key unemitted ⇒ defects > 0 (the check has teeth).
func seam_defects(fid: int) -> int:
	var arr := _build_facet_arrays(fid)
	var edges: Dictionary = arr["edges"]
	var w: int = arr["w"]
	var h: int = arr["h"]
	# Re-derive emit + top exactly as the mesher does.
	var lod := FacetBlockLod.new()
	lod.build(fid)
	var lvl := lod.get_level(LEVEL)
	var top: PackedInt32Array = lvl["top"]
	var dmin := FacetAtlas.dom_min(fid)
	var half := PITCH >> 1
	var emit := PackedByteArray(); emit.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var lx := dmin.x + cx * PITCH + half
			var lz := dmin.y + cz * PITCH + half
			emit[cz * w + cx] = 1 if FacetAtlas.in_polygon(fid, lx, lz, 0.0) else 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var missing := 0
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0:
				continue
			for d: Vector2i in dirs:
				var nx := cx + d.x
				var nz := cz + d.y
				var nb_emit := false
				var nb_top := 0
				if nx >= 0 and nx < w and nz >= 0 and nz < h and emit[nz * w + nx] != 0:
					nb_emit = true
					nb_top = top[nz * w + nx]
				var required := (not nb_emit) or (nb_top < top[ci])
				if not required:
					continue
				var key: String
				if d == Vector2i(1, 0):
					key = "x:%d:%d" % [cx + 1, cz]
				elif d == Vector2i(-1, 0):
					key = "x:%d:%d" % [cx, cz]
				elif d == Vector2i(0, 1):
					key = "z:%d:%d" % [cx, cz + 1]
				else:
					key = "z:%d:%d" % [cx, cz]
				if not edges.has(key):
					missing += 1
	return missing


# ---- helpers ---------------------------------------------------------------------------------------------------

## Absolute-coord world vertex of the integer lattice corner (fid, x, y, z). The shared (fid,x,z) lattice ⇒ any two
## columns meeting at an edge produce BIT-IDENTICAL corners (same f64 inputs → same Vector3) ⇒ no crack (the weld law).
func _w(fid: int, x: int, y: int, z: int) -> Vector3:
	var a := FacetAtlas.lattice_to_world64(fid, float(x), float(y), float(z))
	return Vector3(a[0], a[1], a[2])


func _add_quad(verts: PackedVector3Array, vcol: PackedColorArray, uvs: PackedVector2Array, idx: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, c: Color, arrival: float) -> void:
	var base := verts.size()
	verts.push_back(p0); verts.push_back(p1); verts.push_back(p2); verts.push_back(p3)
	for _i in range(4):
		vcol.push_back(c)
		uvs.push_back(Vector2(arrival, 0.0))          # UV.x = arrival time (screen-door dither clock)
	idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2)
	idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3)


static func _rgba8(c: Color) -> int:
	return (int(round(c.r * 255.0)) << 24) | (int(round(c.g * 255.0)) << 16) \
		| (int(round(c.b * 255.0)) << 8) | int(round(c.a * 255.0))


## The unshaded, vertex-coloured material composing with the shell shade·tint law (radial normal = normalize(wp −
## MODEL·0), identical to _SHELL_ABS_SHADER). Under FP_SHADE_UNIFIED the ONE shared VoxiLight law is string-included
## so L1 shades identically to the near blocks AND the far skin (the user's #1 seamless requirement). Adds the §4
## arrival screen-door DITHER (a discard pattern in this one opaque material — no transparency, no sorting).
func _make_material() -> ShaderMaterial:
	var head := "shader_type spatial;\nrender_mode unshaded, cull_disabled;\n"
	var light: String
	var call: String
	if CubeSphere.FP_SHADE_UNIFIED:
		# The shared law declares sun_dir/night_floor/term_mu/moonshine + voxi_shade(n, sd).
		light = VoxiLight.SHADE_GLSL
		call = "voxi_shade(n, sun_dir)"
	else:
		# Inline shell law (byte-mirrors _SHELL_ABS_SHADER's day/night shade·tint — the shipped far-skin look).
		light = "uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);\n" \
			+ "uniform float night_floor = 0.06;\n" \
			+ "uniform float term_mu = 0.12;\n" \
			+ "float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float hh = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(hh + 6.07995, -1.6364)); }\n" \
			+ "vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }\n" \
			+ "float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }\n" \
			+ "float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }\n" \
			+ "vec3 _sh(vec3 n, vec3 sd) { float mu = dot(n, normalize(sd)); float shade = night_floor + (1.0 - night_floor) * _day(mu); vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu)); return vec3(shade) * tint; }\n"
		call = "_sh(n, sun_dir)"
	# Bayer 4x4 threshold table (÷16) for the arrival screen-door.
	var body := "uniform float u_now = 0.0;\nuniform float u_dither = 0.3;\n" \
		+ "varying vec3 v_col;\nvarying float v_arr;\n" \
		+ "void vertex() {\n" \
		+ "\tvec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n" \
		+ "\tvec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;\n" \
		+ "\tvec3 n = normalize(wp - centre);\n" \
		+ "\tv_col = COLOR.rgb * " + call + ";\n" \
		+ "\tv_arr = UV.x;\n" \
		+ "}\n" \
		+ "const float _bayer[16] = float[](0.0,8.0,2.0,10.0, 12.0,4.0,14.0,6.0, 3.0,11.0,1.0,9.0, 15.0,7.0,13.0,5.0);\n" \
		+ "void fragment() {\n" \
		+ "\tfloat fade = clamp((u_now - v_arr) / max(u_dither, 0.0001), 0.0, 1.0);\n" \
		+ "\tif (fade < 1.0) {\n" \
		+ "\t\tint bx = int(mod(FRAGCOORD.x, 4.0));\n" \
		+ "\t\tint by = int(mod(FRAGCOORD.y, 4.0));\n" \
		+ "\t\tfloat thr = (_bayer[by * 4 + bx] + 0.5) / 16.0;\n" \
		+ "\t\tif (fade < thr) { discard; }\n" \
		+ "\t}\n" \
		+ "\tALBEDO = v_col;\n" \
		+ "}\n"
	var sh := Shader.new()
	sh.code = head + light + body
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("sun_dir", _sun_dir)
	m.set_shader_parameter("u_dither", CubeSphere.BLOCK_LOD_DITHER_S)
	if CubeSphere.FP_SHADE_UNIFIED:
		m.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		m.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		m.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return m
