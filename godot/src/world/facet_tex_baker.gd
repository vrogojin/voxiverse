class_name FacetTexBaker
extends RefCounted
## COSMOS LOD-TEXTURE Phase 1 (docs/COSMOS-LOD-TEXTURE-DESIGN.md §1.1/§6 Phase 1) — the per-facet baked
## "satellite" far texture (BASE MAP only). Owned by WorldManager, created ONLY under FP_FACET_TEX && FACETED
## (mirrors the FacetSkinTier gated-construction pattern). Flag OFF ⇒ this object is never instantiated, so no
## textures / staging Images ever exist (byte-identical, zero bytes).
##
## THE BAKE (§1.1, "CPU composite from the one-generator sampler, then box-average downscale"). Per facet:
##   1. Sample a fine BAKE_SRC×BAKE_SRC grid of the facet's surface via VoxelGeneratorCosmos.sample_columns —
##      the SAME C++ call FacetSkinTier uses (one call per row-slice). Each fine texel = the real top block's
##      catalog colour at that column (FarPalette.color_for through the one-sampler law), i.e. the exact pixels
##      a top-down render of the meshed blocks would produce, without those blocks being resident.
##   2. Box-average the fine grid down to BASE_TEXELS×BASE_TEXELS (2×2 fine texels per stored texel). This is
##      the literal "downscale the real image" of the design (a 50×50 quarry survives; a single block averages
##      out). DEVIATION-NOTE: the design cites Image.resize(INTERPOLATE_BILINEAR); an explicit box average is
##      used instead — it IS the design's stated intent ("box average of the real block colours") and makes
##      the bake headless-deterministic and the G-FT-BAKE box-average assertion exact (ε = 8-bit quantization
##      only), where a bilinear 2× kernel would not be an exact box average.
##   3. Blit the 16² texel block into the facet's rect [a·16..a·16+16)×[b·16..b·16+16) of its cube-FACE page.
## A cube face's 24×24 facets share ONE continuous 384² page, so within-face bilinear filtering across facet
## boundaries is correct continuity — ~99% of potential per-facet texture seams do not exist by construction.
##
## THE STORE (§1.2). 6 face pages → a Texture2DArray of 6 layers of (K·BASE_TEXELS)² = 384² RGBA8 + mipmaps.
## Facet (face,a,b)'s texels align 1:1 with the far ring's ARRAY_TEX_UV = ((a+s)/K,(b+t)/K), so the shader's
## texture(base_map, vec3(uv, face)) samples exactly this bake.
##
## NEVER-OOM (§4, base-tier-only ≈ 8.2 MB). Every buffer is fixed-size at creation: 6 layers, 384², RGBA8.
## Nothing grows with playtime/edits/travel (Phase 1 has no edits, no close-up tier). total_bytes() reports the
## ledger. On the live gl_compat/ANGLE path the Texture2DArray + per-layer update() is the one item that cannot
## be verified headless (design R6) — the single-ImageTexture fallback is a localized swap (base_texture()/the
## page store are the only touch points) if the live smoke fails.

const BASE_TEXELS := 16              # stored texels per facet edge → ground pitch ≈ 26 blocks (§1.2)
const BAKE_SRC := 32                 # fine sample columns per facet edge (2× BASE_TEXELS → exact 2×2 box average)
const DOWNS := BAKE_SRC / BASE_TEXELS # box-average factor (2)

var _k := 0                          # FacetAtlas.K (24) — page = _k·BASE_TEXELS
var _page := 0                       # per-face page edge in texels (384)
var _pages: Array = []               # 6 face Images (RGBA8, mipmaps) — the CPU staging + re-blit source
var _tex: Texture2DArray = null      # the 6-layer GPU base map (bound into the ring's base_map uniform)
var _sampler: Callable               # (fid, PackedInt64Array) -> {heights,biomes,water,colors} (one-sampler law)
var _sampler_obj: Object = null      # STRONG ref to the compiled generator (a Callable does NOT keep it alive)
var _baked: Dictionary = {}          # fid -> true (facets composited into their page this session)

# COSMOS LOD-TEXTURE Phase 2 (§6 / §3.2): progressive BASE-map coverage beyond the spawn hemisphere. `update()`
# bakes uncached facets (nearest-to-emit-axis first, then a global cursor) under a strict per-frame budget so the
# whole planet textures in as the player moves — WITHOUT a main-thread stall. Whole-facet units (~0.9 ms native);
# the budget is CHECKED BEFORE each bake (the FP_ENV_ALL lesson: checking AFTER a heavy unit is the bug). Dirty
# pages upload ≤1/update. Telemetry (`tex_telemetry`) streams the ledger next to shell_telemetry.
var _base_all := 0                   # 6·K² — total facets (coverage-complete sentinel)
var _base_dirty: Dictionary = {}     # face -> true: base pages re-blitted this update, pending an incremental upload
var _budget_spent_us := 0            # last update's total bake wall-us (budget accounting / telemetry)
var _worst_frame_us := 0             # worst per-update bake wall-us this session (the bounded-cost proof surface)
var _base_cursor := 0                # global sweep cursor for coverage of facets outside every emit-axis cap

# COSMOS LOD-TEXTURE Phase 4 (§1.2 T2t / §6 Phase 4): the CLOSE-UP tier. A second Texture2DArray of CLOSEUP_MAX
# layers of CLOSEUP_TEXELS², one cap facet per layer, LRU by angular distance to the emit axis. Each promoted facet
# is baked ROW-SLICED under the shared budget (a 128² one-call bake is ~4 ms — over budget — so it is split into
# CLOSEUP_SLICE_ROWS-row slices, ~0.5 ms each, resumed across frames). A promoted facet shows the coarser base map
# (or vertex colour) until its layer is ready → no hitch, no hole. NEVER-OOM: fixed CLOSEUP_MAX layers, LRU evicts
# ONLY facets outside the current cap (the base map is the safe floor). All zero / never created with the flag off.
var _cu_on := false                  # FP_FACET_TEX_CLOSEUP && the baker exists (set in setup)
var _cu_texels := 0                  # CLOSEUP_TEXELS (128)
var _cu_tex: Texture2DArray = null   # the CLOSEUP_MAX-layer GPU close-up map (bound into the ring's closeup_map)
var _cu_layers: Array = []           # CLOSEUP_MAX staging Images (128² RGBA8, premult+mips) — the re-blit source
var _cu_slots: Dictionary = {}       # fid -> layer (RESIDENT: baked + uploaded; the value fed to UV2.y)
var _cu_facet := PackedVector2Array() # layer -> (a,b) reverse map for the shader's `cu_facet` uniform (exact facet-local UV)
var _cu_free: Array = []             # currently free layer indices (LRU reuse pool)
var _cu_want: Dictionary = {}        # fid -> cos(angle to emit axis): facets currently inside the promotion cap
var _cu_want_axis: Array = [2.0, 0.0, 0.0]  # emit axis the want-set was last computed for (>1 sentinel ⇒ force first)
var _cu_bake_fid := -1               # facet whose 128² bake is in progress (row-sliced across frames); -1 = idle
var _cu_bake_layer := -1             # the layer that in-progress bake will occupy
var _cu_bake_row := 0                # next fine row to sample for the in-progress bake (0..CLOSEUP_TEXELS)
var _cu_bake_img: Image = null       # the in-progress 128² staging image (transparent until rows fill in)
var _cu_bake_lc := PackedVector2Array()  # the in-progress facet's 4 lattice corners (computed once per facet)
var _cu_dirty: Dictionary = {}       # layer -> true: baked this update, pending an incremental update_layer upload
var _slots_epoch := 0                # bumped on any _cu_slots change so WorldManager pushes the new map to the ring
# Cached facet centre directions (one PackedVector3Array of 6·K², indexed by local fid) so the per-update want/base
# scans are cheap dot products, NOT 4 facet_planar_corner calls per facet per scan (that was a ~10 ms unbudgeted
# stall). Built once (setup); bounded ⇒ NEVER-OOM. Mirrors FacetFarRing._centre_pack.
var _centre_pack := PackedVector3Array()

# --- lifecycle -----------------------------------------------------------------------------------

## Build this epoch's sampler (compiled VoxelGeneratorCosmos frozen for `active_fid`, else the GDScript oracle
## — byte-equal by G-CG-COLUMNS) and allocate the 6 empty face pages. Mirrors FacetSkinTier.setup.
func setup(active_fid: int) -> void:
	_k = FacetAtlas.K
	_page = _k * BASE_TEXELS
	_sampler_obj = FacetSkinTier._build_cpp_gen(active_fid)
	if _sampler_obj != null:
		_sampler = Callable(_sampler_obj, "sample_columns")
	else:
		push_warning("FacetTexBaker: VoxelGeneratorCosmos absent — using the GDScript oracle sampler (slow).")
		_sampler = Callable(FacetSkinTier, "gd_sample")
	# COVERAGE SENTINEL (§ live-fix): un-baked texels stay ALPHA 0. The shell shader gates the vertex-colour↔
	# texture blend on texel alpha (wt *= texel.a), so a facet the prewarm/Phase-2 driver has NOT baked yet
	# samples alpha 0 → wt 0 → the shipped vertex-colour far ring (NEVER a black un-baked hemisphere from orbit).
	# A baked texel is written alpha 1 by bake_facet. This is per-texel coverage — strictly better than a
	# per-facet flag (soft boundary, no per-vertex plumbing, worker-safe) and composes with Phase 2's progressive
	# bake (a facet lights up the moment its texels turn opaque).
	_pages.resize(6)
	for f in range(6):
		var img := Image.create(_page, _page, true, Image.FORMAT_RGBA8)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
		_pages[f] = img
	_base_all = 6 * _k * _k
	_ensure_centre_pack()               # one-time centre-dir cache → cheap per-update want/base scans
	# COSMOS LOD-TEXTURE Phase 4: allocate the CLOSE-UP staging layers (fixed CLOSEUP_MAX × 128² → NEVER-OOM) and
	# seed the free-layer pool. Only under FP_FACET_TEX_CLOSEUP → zero close-up bytes with the flag off.
	_cu_on = CubeSphere.FP_FACET_TEX_CLOSEUP
	if _cu_on:
		_cu_texels = CubeSphere.CLOSEUP_TEXELS
		_cu_layers.resize(CubeSphere.CLOSEUP_MAX)
		_cu_facet.resize(CubeSphere.CLOSEUP_MAX)
		_cu_free.clear()
		var cimgs: Array[Image] = []
		for i in range(CubeSphere.CLOSEUP_MAX):
			var cimg := Image.create(_cu_texels, _cu_texels, true, Image.FORMAT_RGBA8)
			cimg.fill(Color(0.0, 0.0, 0.0, 0.0))
			_cu_layers[i] = cimg
			_cu_facet[i] = Vector2(-1.0, -1.0)
			_cu_free.append(i)
			cimgs.append(cimg)
		# Build the GPU close-up array ONCE at setup (all-transparent → the shader samples a=0 → base-map fallback),
		# so a completed bake only does a cheap per-layer update_layer — never a mid-play create_from_images spike.
		_cu_tex = Texture2DArray.new()
		_cu_tex.create_from_images(cimgs)

## Synchronous prewarm of the currently-emitted facet set (§6 Phase 1). Bakes each facet's base map into its
## page, then uploads the whole 6-layer array once. Masked by the same ShaderPrewarm hold as the ring's initial
## _rebuild_full (WorldManager calls this at setup with the ring's visible_fids()).
func prewarm(fids: PackedInt32Array) -> void:
	for fid in fids:
		bake_facet(int(fid))
	_rebuild_texture()

# --- the bake (§1.1) -----------------------------------------------------------------------------

## The fine BAKE_SRC×BAKE_SRC grid of top-block colours for facet `fid` in ONE sample_columns call (LOW #4:
## the whole ~1024-column facet at once, like FacetSkinTier's 1089-column tile — ~32× fewer calls than a
## per-row bake; the per-row slice is reserved for Phase 2's budgeted path). fi → s, fj → t, matching the far
## ring's UV = ((a+s)/K,(b+t)/K). Public so the gate re-samples the SAME grid the bake box-averages (G-FT-BAKE)
## — the sampler is pure, so two calls are byte-identical.
func sample_fine(fid: int) -> PackedColorArray:
	# The facet's 4 lattice (x,z) corners: its param (s,t)=00,10,11,01 corners mapped through the exact
	# world_to_lattice64, so a fine param maps to the lattice column sample_columns wants (cell_dir agrees).
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	var packed := PackedInt64Array()
	packed.resize(BAKE_SRC * BAKE_SRC)
	for fj in range(BAKE_SRC):
		var t := (float(fj) + 0.5) / float(BAKE_SRC)
		var row := fj * BAKE_SRC
		for fi in range(BAKE_SRC):
			var s := (float(fi) + 0.5) / float(BAKE_SRC)
			var lx := _bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)
			var lz := _bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)
			packed[row + fi] = _pack_xz(int(round(lx)), int(round(lz)))
	var res: Dictionary = _sampler.call(fid, packed)   # ONE C++ call for the whole facet
	return res["colors"]

## Composite facet `fid`'s base map into its cube-face page: box-average the fine grid down to BASE_TEXELS²
## and blit into the facet's rect [a·16..)×[b·16..). Idempotent (a re-bake overwrites the same rect bit-exactly
## → G-FT-BAKE determinism). Does NOT upload — prewarm()/the gate call _rebuild_texture() after a batch.
func bake_facet(fid: int) -> void:
	var d := _decode(fid)
	var face: int = d[0]
	var a: int = d[1]
	var b: int = d[2]
	var fine := sample_fine(fid)
	var img: Image = _pages[face]
	var ox := a * BASE_TEXELS
	var oy := b * BASE_TEXELS
	var inv := 1.0 / float(DOWNS * DOWNS)
	for ty in range(BASE_TEXELS):
		for tx in range(BASE_TEXELS):
			var r := 0.0
			var g := 0.0
			var bl := 0.0
			for sy in range(DOWNS):
				var row := (ty * DOWNS + sy) * BAKE_SRC + tx * DOWNS
				for sx in range(DOWNS):
					var c: Color = fine[row + sx]
					r += c.r
					g += c.g
					bl += c.b
			img.set_pixel(ox + tx, oy + ty, Color(r * inv, g * inv, bl * inv, 1.0))
	_baked[fid] = true

## (Re)generate mipmaps on every page and (re)build the GPU Texture2DArray. Phase 1 builds it once after the
## prewarm batch; the per-layer update_layer path (Phase 2/3) is retained for the incremental case.
func _rebuild_texture() -> void:
	var imgs: Array[Image] = []
	for f in range(6):
		var img: Image = _pages[f]
		# COVERAGE-CORRECT MIPS (§ live-fix 2): premultiply RGB by A BEFORE generate_mipmaps. Godot box-filters
		# R/G/B independently of A (straight alpha), so a boundary mip texel between a baked facet (rgb, a=1) and
		# an un-baked one (0, a=0) would average real colour with literal BLACK into rgb → a dark seam along the
		# bake frontier once wt>0 (cam_dist>600). Premultiplied, the box filter becomes coverage-weighted
		# (rgb = Σ rgb·a / N, a = Σ a / N), so an un-baked texel contributes 0 to BOTH sums; the shell shader
		# un-premultiplies on read (col = rgb/a) to recover the true colour. No-op on mip-0 baked texels (a=1 ⇒
		# rgb·1) so G-FT-BAKE (get_pixel at mip 0) is unchanged; idempotent on the a∈{0,1} sentinel so a Phase-2
		# re-blit + re-upload stays correct.
		img.premultiply_alpha()
		img.generate_mipmaps()
		imgs.append(img)
	if _tex == null:
		_tex = Texture2DArray.new()
		_tex.create_from_images(imgs)
	else:
		for f in range(6):
			_tex.update_layer(imgs[f], f)

# --- Phase 2 (progressive base coverage) + Phase 4 (close-up) per-frame driver -------------------

## The per-frame bake driver (docs/COSMOS-LOD-TEXTURE-DESIGN.md §3.2 / §6 Phase 2+4). Driven from
## WorldManager.update_streaming (main thread), once per physics tick, with the emit axis + off-surface state from
## the far ring and a strict `budget_ms` (CubeSphere.FACET_TEX_BAKE_BUDGET_MS).
##
## THE HARD PERF CONSTRAINT (§ the make-or-break, learned repeatedly this session): a per-facet bake is heavy and
## MUST NOT stall the frame. So: (1) the budget is measured from `start` and CHECKED BEFORE each bake unit begins
## (never after — the FP_ENV_ALL bug was checking after a 16 ms unit); (2) the close-up 128² bake (~4 ms in one
## call) is split into CLOSEUP_SLICE_ROWS-row slices (~0.5 ms) resumed across frames; (3) the base map bakes at
## most a bounded number of whole facets (~0.9 ms each) per update. Worst-case per-update bake cost is therefore
## budget + one unit — bounded by construction, and PROVEN by the headless G-FT-BUDGET scripted drive (which asserts
## `worst_frame_ms` never exceeds the bound and the loop never STARTED a unit past the budget line).
func update(emit_axis: Array, offsurface: bool, budget_ms: float) -> void:
	var start := Time.get_ticks_usec()
	var budget_us := int(budget_ms * 1000.0)
	# Split the shared budget so BOTH tiers progress every frame: the close-up crisp win (off-surface) gets the first
	# CU_SHARE, base coverage the remainder — so a rotating orbit never starves progressive base coverage, and when the
	# close-up cap is fully resident its unused share falls through to base. Both sub-phases check the budget BEFORE each
	# unit (never mid-unit), so the worst frame is bounded by budget + one bake unit regardless of the split.
	var cu_line := int(float(budget_us) * 0.75)
	if _cu_on and offsurface:
		_recompute_want(emit_axis)
		_bake_closeup_budgeted(start, cu_line)
	elif _cu_on and not _cu_want.is_empty():
		_evict_all_closeup()               # on-surface (or flag path change): drop every promotion → all base-map, bytes freed to the pool
	# Phase 2: progressive BASE coverage with the remaining budget (whole-facet units, check-before-each).
	_bake_base_progressive(start, budget_us, emit_axis)
	# Bounded incremental uploads (main-thread RenderingServer touch): ≤ a few pages/layers per update.
	_flush_base_uploads()
	_flush_closeup_uploads()
	var spent := Time.get_ticks_usec() - start
	_budget_spent_us = spent
	_worst_frame_us = maxi(_worst_frame_us, spent)

# --- Phase 2: progressive base-map coverage ------------------------------------------------------

## Bake uncached base-map facets until the budget line is reached. Priority: the unbaked facet NEAREST the emit
## axis (coverage grows where the player looks), falling back to a global cursor sweep so the WHOLE planet is
## eventually covered even for longitudes never looked at. Whole-facet units; the budget is checked BEFORE each.
func _bake_base_progressive(start: int, budget_us: int, axis: Array) -> void:
	if _baked.size() >= _base_all:
		return
	while _baked.size() < _base_all:
		if Time.get_ticks_usec() - start >= budget_us:
			return                          # budget line reached → resume next update (CHECK-BEFORE, never mid-unit)
		var fid := _next_base_fid(axis)
		if fid < 0:
			return
		bake_facet(fid)
		_base_dirty[face_of(fid)] = true

## The next base facet to bake: the unbaked facet with the largest dot to `axis` (nearest the sub-camera point),
## else advance the global cursor to the next unbaked fid (whole-planet coverage). Returns -1 when all are baked.
func _next_base_fid(axis: Array) -> int:
	var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
	var best := -1
	var best_dot := -2.0
	# Axis-nearest pass (bounded 6·K² dot tests — microseconds). Only meaningful when `axis` is a real unit vector.
	if ax * ax + ay * ay + az * az > 0.5:
		var total := _base_all
		for fid in range(total):
			if _baked.has(fid):
				continue
			var cd := _centre_pack[fid]
			var d := cd.x * ax + cd.y * ay + cd.z * az
			if d > best_dot:
				best_dot = d; best = fid
		if best >= 0:
			return best
	# Fallback cursor sweep (no axis / covered near the axis): first unbaked fid from the rolling cursor.
	for _i in range(_base_all):
		var fid := _base_cursor
		_base_cursor = (_base_cursor + 1) % _base_all
		if not _baked.has(fid):
			return fid
	return -1

## Upload the base pages re-blitted this update — premultiply + regen mips + one per-layer update_layer each (the
## §1.2 partial-upload path). Idempotent premultiply on the a∈{0,1} sentinel (matches _rebuild_texture).
func _flush_base_uploads() -> void:
	if _base_dirty.is_empty():
		return
	if _tex == null:
		_rebuild_texture()                  # first coverage bake before any prewarm built the array — build it whole
		_base_dirty.clear()
		return
	for face in _base_dirty.keys():
		var img: Image = _pages[int(face)]
		img.premultiply_alpha()
		img.generate_mipmaps()
		_tex.update_layer(img, int(face))
	_base_dirty.clear()

# --- Phase 4: close-up promotion + row-sliced bake -----------------------------------------------

## Recompute the promotion cap (facets within CLOSEUP_CAP_DEG of `axis`) and EVICT residents that have left it.
## Axis-gated (a still camera re-runs nothing). Eviction frees the layer back to the pool — the base map covers the
## evicted facet (wc≈0 outside the cap), so it is invisible (gate G-FT-SLOT asserts evict-only-outside-cap).
func _recompute_want(axis: Array) -> void:
	var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
	if ax * ax + ay * ay + az * az < 0.5:
		return                              # degenerate axis (camera at centre) — hold the last want-set
	# Axis-change gate: skip while the axis is essentially unchanged (a tight fraction of the cap half-angle).
	var facet_ang := (PI * 0.5) / float(_k)
	var hold_cos := cos(0.25 * facet_ang)
	if not _cu_want.is_empty() and _cu_want_axis[0] * ax + _cu_want_axis[1] * ay + _cu_want_axis[2] * az >= hold_cos:
		return
	_cu_want_axis = [ax, ay, az]
	var cos_thr := cos(deg_to_rad(CubeSphere.CLOSEUP_CAP_DEG))
	var want := {}
	for fid in range(_base_all):
		var cd := _centre_pack[fid]
		var d := cd.x * ax + cd.y * ay + cd.z * az
		if d >= cos_thr:
			want[fid] = d
	# Evict residents no longer wanted (outside the cap) — the invariant the gate checks.
	for fid in _cu_slots.keys():
		if not want.has(int(fid)):
			_evict_closeup(int(fid))
	# If the in-progress bake's facet left the cap, abandon it (its layer returns to the pool).
	if _cu_bake_fid >= 0 and not want.has(_cu_bake_fid):
		_cu_free.append(_cu_bake_layer)
		_cu_bake_fid = -1; _cu_bake_layer = -1; _cu_bake_img = null
	_cu_want = want

## Bake promoted-but-not-resident facets (nearest the axis first), ROW-SLICED, until the budget line. Continues an
## in-progress facet across updates. A facet needs a free/evictable layer to start; if all layers are in-cap
## residents, it is skipped (stays base map) — NEVER evicts an in-cap facet.
func _bake_closeup_budgeted(start: int, budget_us: int) -> void:
	while Time.get_ticks_usec() - start < budget_us:   # CHECK-BEFORE each slice (never mid-slice)
		if _cu_bake_fid < 0:
			var fid := _next_want_to_bake()
			if fid < 0:
				return                      # nothing left to promote this cap
			if not _begin_closeup_bake(fid):
				return                      # no evictable layer (all in-cap) — leave the rest on the base map
		_bake_closeup_slice()

## The nearest wanted facet that is neither resident nor already baking. -1 when the cap is fully resident/queued.
func _next_want_to_bake() -> int:
	var best := -1
	var best_dot := -2.0
	for fid in _cu_want.keys():
		var f := int(fid)
		if _cu_slots.has(f) or f == _cu_bake_fid:
			continue
		var d: float = _cu_want[fid]
		if d > best_dot:
			best_dot = d; best = f
	return best

## Acquire a layer for `fid` and start its row-sliced bake. Prefers a free layer; else evicts the FARTHEST resident
## that is OUTSIDE the cap (LRU by angular distance). Returns false if every layer is an in-cap resident (no evict).
func _begin_closeup_bake(fid: int) -> bool:
	var layer := -1
	if not _cu_free.is_empty():
		layer = int(_cu_free.pop_back())
	else:
		# Find the resident with the smallest dot to the axis that is NOT in the current want cap (outside → evictable).
		var victim := -1
		var victim_dot := 2.0
		var ax := float(_cu_want_axis[0]); var ay := float(_cu_want_axis[1]); var az := float(_cu_want_axis[2])
		for rf in _cu_slots.keys():
			var r := int(rf)
			if _cu_want.has(r):
				continue                    # in-cap → never evict
			var cd := _centre_pack[r]
			var d := cd.x * ax + cd.y * ay + cd.z * az
			if d < victim_dot:
				victim_dot = d; victim = r
		if victim < 0:
			return false                    # all layers are in-cap residents — do not evict; `fid` stays base map
		layer = int(_cu_slots[victim])
		_evict_closeup(victim)
		# _evict_closeup pushed `layer` to the free pool; take it straight back for this bake.
		_cu_free.erase(layer)
	_cu_bake_fid = fid
	_cu_bake_layer = layer
	_cu_bake_row = 0
	var img: Image = _cu_layers[layer]
	img.fill(Color(0.0, 0.0, 0.0, 0.0))     # clear the (possibly evicted) staging layer before re-baking
	_cu_bake_img = img
	# The facet's 4 lattice corners (once per facet), same mapping as sample_fine.
	_cu_bake_lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		_cu_bake_lc[ci] = Vector2(float(l[0]), float(l[2]))
	return true

## Sample CLOSEUP_SLICE_ROWS more rows of the in-progress facet's 128² fine grid (one sample_columns call each) and
## write the top-block colours straight (alpha 1) into the staging layer. On the last row: premultiply + mips, mark
## the layer dirty (upload), make it RESIDENT (_cu_slots[fid]=layer) + record its (a,b) in the shader reverse-map.
func _bake_closeup_slice() -> void:
	var n := _cu_texels
	var r0 := _cu_bake_row
	var r1 := mini(r0 + CubeSphere.CLOSEUP_SLICE_ROWS, n)
	var rows := r1 - r0
	var packed := PackedInt64Array()
	packed.resize(rows * n)
	var lc := _cu_bake_lc
	for rj in range(rows):
		var fj := r0 + rj
		var t := (float(fj) + 0.5) / float(n)
		var base := rj * n
		for fi in range(n):
			var s := (float(fi) + 0.5) / float(n)
			var lx := _bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)
			var lz := _bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)
			packed[base + fi] = _pack_xz(int(round(lx)), int(round(lz)))
	var res: Dictionary = _sampler.call(_cu_bake_fid, packed)
	var cols: PackedColorArray = res["colors"]
	var img: Image = _cu_bake_img
	for rj in range(rows):
		var fj := r0 + rj
		var base := rj * n
		for fi in range(n):
			var c: Color = cols[base + fi]
			img.set_pixel(fi, fj, Color(c.r, c.g, c.b, 1.0))
	_cu_bake_row = r1
	if r1 < n:
		return                              # more slices next update
	# Facet complete → premultiply + mips (coverage-correct like the base page), mark resident + dirty.
	img.premultiply_alpha()
	img.generate_mipmaps()
	var layer := _cu_bake_layer
	var fid := _cu_bake_fid
	_cu_slots[fid] = layer
	var d := _decode(fid)
	_cu_facet[layer] = Vector2(float(d[1]), float(d[2]))
	_cu_dirty[layer] = true
	_slots_epoch += 1
	_cu_bake_fid = -1; _cu_bake_layer = -1; _cu_bake_img = null

## Evict facet `fid`: free its layer, drop it from the resident map (→ base map on the next re-emit). Bumps the epoch.
func _evict_closeup(fid: int) -> void:
	if not _cu_slots.has(fid):
		return
	var layer := int(_cu_slots[fid])
	_cu_slots.erase(fid)
	# Deliberately DO NOT reset _cu_facet[layer] here: an evicted facet is dropped from _cu_slots (→ UV2.y −1 on the
	# next re-emit), but for the ≤1-frame window before that re-emit lands its mesh vertices still carry this slot. If
	# they sampled a reset (-1,-1) reverse-map they would read a wrong local UV; leaving the (a,b) as-is keeps them
	# sampling THEIR OWN (still-resident) layer image at the correct local coord (a soft no-op) until the layer is
	# actually reused by _begin_closeup_bake (which fills it transparent + rewrites _cu_facet on completion).
	if not _cu_free.has(layer):
		_cu_free.append(layer)
	_slots_epoch += 1

## Drop ALL close-up promotions (on-surface / flag path change): every layer returns to the pool, all facets fall
## back to the base map. Bounded; frees no CPU/GPU bytes (fixed-size arrays) — only the resident bookkeeping.
func _evict_all_closeup() -> void:
	for fid in _cu_slots.keys():
		_evict_closeup(int(fid))
	if _cu_bake_fid >= 0:
		_cu_free.append(_cu_bake_layer)
		_cu_bake_fid = -1; _cu_bake_layer = -1; _cu_bake_img = null
	_cu_want.clear()
	_cu_want_axis = [2.0, 0.0, 0.0]

## Upload the close-up layers baked this update (create the array lazily on the first). Bounded ≤ a few/update.
func _flush_closeup_uploads() -> void:
	if not _cu_on or _cu_dirty.is_empty():
		return
	if _cu_tex == null:
		var imgs: Array[Image] = []
		for i in range(CubeSphere.CLOSEUP_MAX):
			imgs.append(_cu_layers[i])
		_cu_tex = Texture2DArray.new()
		_cu_tex.create_from_images(imgs)
	else:
		for layer in _cu_dirty.keys():
			_cu_tex.update_layer(_cu_layers[int(layer)], int(layer))
	_cu_dirty.clear()

func _centre_dir(fid: int) -> Array:
	var v := _cdir(fid)
	return [v.x, v.y, v.z]

## Build the centre-dir pack ONCE (6·K² Vector3, indexed by local fid). Idempotent; bounded ⇒ NEVER-OOM.
func _ensure_centre_pack() -> void:
	var total := 6 * _k * _k
	if _centre_pack.size() == total:
		return
	_centre_pack.resize(total)
	var k := _k
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				var s := Vector3.ZERO
				for ci in range(4):
					var c := FacetAtlas.facet_planar_corner(fid, ci)
					s += Vector3(float(c[0]), float(c[1]), float(c[2]))
				_centre_pack[fid] = s.normalized()

## The cached facet centre direction (unit). Requires _ensure_centre_pack (called in setup).
func _cdir(fid: int) -> Vector3:
	return _centre_pack[fid]

# --- accessors / gate surface --------------------------------------------------------------------

## The 6-layer base map bound into the far ring's `base_map` uniform (null until the first prewarm/bake batch).
func base_texture() -> Texture2DArray:
	return _tex

## The cube-face layer index of facet `fid` (0..5) — the base-map array layer its texels live in.
func face_of(fid: int) -> int:
	return _decode(fid)[0]

## The stored (RGBA8 mip-0) texel colour at facet `fid`'s local texel (tx,ty) ∈ [0,BASE_TEXELS)². Gate surface
## for G-FT-BAKE / G-FT-PALETTE (reads the page after bake_facet).
func texel_color(fid: int, tx: int, ty: int) -> Color:
	var d := _decode(fid)
	var img: Image = _pages[int(d[0])]
	return img.get_pixel(int(d[1]) * BASE_TEXELS + tx, int(d[2]) * BASE_TEXELS + ty)

func is_baked(fid: int) -> bool:
	return _baked.has(fid)

func baked_count() -> int:
	return _baked.size()

# --- Phase 4 close-up accessors + telemetry (gate + WorldManager surface) -------------------------

## The CLOSEUP_MAX-layer close-up map bound into the ring's `closeup_map` uniform (null until the first bake). Off ⇒ null.
func closeup_texture() -> Texture2DArray:
	return _cu_tex

## The RESIDENT close-up layer for `fid`, or −1 (base-map fallback). This is the value fed to UV2.y at emit.
func closeup_slot(fid: int) -> int:
	return int(_cu_slots.get(fid, -1))

## A COPY of the resident slot map (fid→layer) for WorldManager to push to the ring each time the epoch bumps.
func closeup_slots() -> Dictionary:
	return _cu_slots.duplicate()

## The layer→(a,b) reverse map for the shader's `cu_facet` uniform (exact facet-local UV without an in-shader floor).
func closeup_facet_map() -> PackedVector2Array:
	return _cu_facet

## Bumped on any resident-slot change → WorldManager pushes the new map to the ring + requests a re-emit.
func slots_epoch() -> int:
	return _slots_epoch

func closeup_resident_count() -> int:
	return _cu_slots.size()

func closeup_want_count() -> int:
	return _cu_want.size()

## Is facet `fid` currently inside the promotion cap? (gate G-FT-SLOT: evict-only-outside-cap invariant.)
func closeup_in_cap(fid: int) -> bool:
	return _cu_want.has(fid)

## The stored (mip-0) close-up texel at layer-facet `fid`'s (tx,ty) ∈ [0,CLOSEUP_TEXELS)². Un-premultiplied for the
## gate (the staging layer is premultiplied post-bake, so recover the true colour by /a; a=0 ⇒ transparent). -1 slot ⇒
## returns transparent black (not resident). Gate surface for G-FT-CLOSEUP-BAKE.
func closeup_texel_color(fid: int, tx: int, ty: int) -> Color:
	if not _cu_slots.has(fid):
		return Color(0.0, 0.0, 0.0, 0.0)
	var img: Image = _cu_layers[int(_cu_slots[fid])]
	var c := img.get_pixel(tx, ty)
	if c.a > 0.0001:
		return Color(c.r / c.a, c.g / c.a, c.b / c.a, c.a)
	return c

func worst_frame_ms() -> float:
	return float(_worst_frame_us) / 1000.0

func budget_spent_ms() -> float:
	return float(_budget_spent_us) / 1000.0

## Phase 2 telemetry (§6): the bake ledger streamed next to shell_telemetry() via the remote bridge. Bytes + coverage
## + close-up residency + the bounded-cost proof (worst per-update bake ms). {} when nothing has been baked yet.
func tex_telemetry() -> Dictionary:
	return {
		"tex_baked": _baked.size(),
		"tex_total": _base_all,
		"tex_spent_ms": snappedf(budget_spent_ms(), 0.01),
		"tex_worst_ms": snappedf(worst_frame_ms(), 0.01),
		"tex_bytes_kb": total_bytes() / 1024,
		"cu_on": _cu_on,
		"cu_resident": _cu_slots.size(),
		"cu_want": _cu_want.size(),
		"cu_free": _cu_free.size(),
		"cu_epoch": _slots_epoch,
	}

## The TRUE NEVER-OOM footprint (§4): 6 CPU base pages + the base GPU array (+mips ≈ ×1.33) ≈ 8.2 MB; plus, under
## FP_FACET_TEX_CLOSEUP, CLOSEUP_MAX CPU staging layers + the close-up GPU array (+mips) ≈ 9.6 MB → ≈ 17.8 MB all-on.
## The gate asserts it stays under FACET_TEX_BYTES_MAX (20 MB). Every buffer is fixed-size at creation.
const FACET_TEX_BYTES_MAX := 20 * 1024 * 1024
func total_bytes() -> int:
	var page_px := _page * _page * 4          # one RGBA8 base page, bytes
	var cpu := 6 * page_px                     # 6 CPU staging Images (kept for re-blit)
	var gpu := (6 * page_px * 4) / 3           # GPU array + mipmap tail (×1.333)
	var total := cpu + gpu
	if _cu_on:
		var lpx := _cu_texels * _cu_texels * 4    # one RGBA8 close-up layer, bytes
		var cu_cpu := CubeSphere.CLOSEUP_MAX * lpx                 # fixed CLOSEUP_MAX staging layers
		var cu_gpu := (CubeSphere.CLOSEUP_MAX * lpx * 4) / 3       # GPU array + mip tail (×1.333)
		total += cu_cpu + cu_gpu
	return total

# --- helpers -------------------------------------------------------------------------------------

## Decode `fid` → [face, a, b, k] in its body's local (face,a,b) indexing (Earth ⇒ base 0, k=K). Mirrors
## FacetAtlas.facet_corner_dirs' decode so UV = ((a+s)/k,(b+t)/k) and the page rect agree with the far ring.
func _decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

## Bilinear over facet param corners (v00,v10,v11,v01) at (s,t) — the SAME kernel FacetFarRing/_ensure_cached
## uses, so a fine param maps identically to how the mesh maps a grid node.
static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## Pack a lattice column (x,z) into the int64 sample_columns expects: x low 32 bits, z high 32 (== skin's).
static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)
