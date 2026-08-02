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

# COSMOS TEXTURED-LOD V3 (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.1: FP_PAGES_SHOT) — the g0/g1 two-generation page
# bake. g0 = today's FarPalette biome-colour box-average (prewarm + progressive coverage, so BOOT is unchanged/fast).
# g1 = a background cursor that re-bakes each ALREADY-covered facet as a box-downscale of the REAL surface shot
# (SurfaceShot.surface_shot: tint × static-shade, trees composited) — nearest-emit-axis first, then a global sweep, so
# the whole planet converges to shot coverage lazily AFTER boot. Off (_shot_on false) ⇒ the g1 cursor never runs and
# _bake_facet_pixels always bakes the palette colour ⇒ byte-identical. Close-up pages bake shot directly under _shot_on
# (they are transient/promotion-driven, never part of boot). NEVER-OOM: _shot_baked is one bounded 6·K² dict; no new
# textures; the shot scratch is a transient BAKE_SRC² PackedColorArray pair.
var _shot_on := false                # FP_PAGES_SHOT && the baker exists (set in setup; requires FP_FACET_TEX structurally)
var _shot_baked: Dictionary = {}     # fid -> true: facets whose page has been re-baked to the real shot (g1 coverage)
var _shot_cursor := 0                # global g1 sweep cursor (whole-planet shot convergence beyond the emit-axis cap)

# COSMOS TEXTURED-LOD T1b (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R.1): the per-texel material-id page(s), baked ALONGSIDE
# the colour page under FP_BLOCK_DETAIL. 6 face pages of _page² L8 (id 0 = un-baked; id = FarPalette.detail_pattern + 1),
# texelFetch NEAREST in the shader — a SEPARATE texture from the colour page so the premultiplied-coverage frontier law
# (_rebuild_texture) stays byte-untouched and a LINEAR colour page never smears ids. All zero / never created off the
# flag. NEVER-OOM: fixed 6 × _page² L8 (no mips), a fraction of the colour ledger.
var _bd_on := false                  # FP_BLOCK_DETAIL && the baker exists (set in setup)
var _id_pages: Array = []            # 6 face Images (L8) — CPU staging + re-blit source for the id map
var _id_tex: Texture2DArray = null   # the 6-layer GPU id map (bound into the ring's id_map uniform)

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

# COSMOS TEXTURED-LOD U1 (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2U.1: FP_BAND_BLOCK_MAP) — the near-far BAND's REAL
# per-block id map. A BAND_LAYERS×BAND_TEXELS² L8 Texture2DArray: layer `slot` holds facet fid's per-block material id
# (FarPalette.detail_pattern+1, from the SAME sampler colour chain FacetBlockLod L0 classifies — 1 block per texel,
# NO box-average, so the real arrangement survives). PARAM-space (texel (bx,by) = the top block at facet param
# ((bx+0.5)/Nx,(by+0.5)/Ny)) so it covers exactly the visible facet quad [0,1]² and fits 512 even where the lattice
# DOMAIN bbox exceeds it (measured up to 583; the core facet edge is ≤ ~410). The shader reads band_facet[slot]=(a,b)
# + band_n[slot]=(Nx,Ny) to map a fragment's facet-uv → block coord. Residency = active ∪ ring-1 (≤ BAND_LAYERS);
# chunk-row (BAND_SLICE_ROWS) sliced under the shared budget; evicted only on ring exit; a returning facet re-bakes.
# All zero / never created off FP_BAND_BLOCK_MAP. NEVER-OOM: fixed BAND_LAYERS × BAND_TEXELS² L8 + ONE staging layer.
var _bm_on := false                  # FP_BAND_BLOCK_MAP && _bd_on && the baker exists (set in setup)
var _bm_shot := false                # COSMOS TEXTURED-LOD §2V V2: FP_BAND_SHOT && _bm_on ⇒ band is RG8 {id,shade} (real shot incl trees)
var _bm_flat := false                # FP_SKIN_FLATCOLOR: band is L8 {far-colour-index+1} (Minecraft map skin, tile-mean colour incl trees/edits)
var _edit_snap := {}                 # FP_SKIN_FLATCOLOR: main-thread snapshot of the bake facet's edits {Vector2i(lx,lz)->block_id}; empty until Stage-B wires it
var _bm_texels := 0                  # BAND_TEXELS (512)
var _bm_tex: Texture2DArray = null   # the BAND_LAYERS-layer GPU band id map (bound into the ring's band_map uniform)
var _bm_slots: Dictionary = {}       # fid -> layer (RESIDENT: baked + uploaded; the value fed to UV2.y as 64+layer)
var _bm_facet := PackedVector2Array()  # layer -> (a,b) reverse map for the shader's band_facet uniform
var _bm_n := PackedVector2Array()      # layer -> (Nx,Ny) block-count reverse map for the shader's band_n uniform
var _bm_free: Array = []             # free layer indices (reuse pool)
var _bm_want: Dictionary = {}        # fid -> true: the current band set (active ∪ ring-1, capped to BAND_LAYERS)
var _bm_want_active := -1            # the active fid the want-set was last computed for (skip the recompute when unchanged)
var _bm_bake_fid := -1              # facet whose band bake is in progress (row-sliced across frames); -1 = idle
var _bm_bake_layer := -1           # the layer that in-progress bake will occupy
var _bm_bake_row := 0              # next block row (by) to sample for the in-progress bake (0..Ny)
var _bm_bake_img: Image = null      # the in-progress BAND_TEXELS² staging image (L8 {id} / RG8 {id,shade} under FP_BAND_SHOT; id 0 until rows fill in)
var _bm_bake_bytes := PackedByteArray()   # FP_SKIN_FLATCOLOR: the L8 index bytes filled by the slices (direct byte writes, NO set_pixel → fast + unambiguous); the image is built from this at the last slice
# FP_SKIN_FLATCOLOR MULTI-CORE band bake: fan N full-facet bakes across WorkerThreadPool (one per core) instead of the
# single-in-flight JobLane unit. Each slot is a fully independent full-facet compute (pure: sample_columns + tree +
# edit snapshot → L8 byte buffer); main commits finished slots each frame. Residency structures (_bm_slots/_bm_free/
# _bm_facet/_bm_n/_bm_epoch/_bm_want) are shared with the single path but written ONLY on main (single-writer).
var _pbm_on := false
var _pbm_n := 0
var _pbm_fid: Array = []            # slot -> fid being computed (-1 idle) [main-written pre-dispatch, worker-read]
var _pbm_layer: Array = []          # slot -> reserved band layer
var _pbm_task: Array = []           # slot -> WorkerThreadPool task id
var _pbm_bytes: Array = []          # slot -> PackedByteArray result (worker-written under _pbm_mutex)
var _pbm_lc: Array = []             # slot -> PackedVector2Array lattice corners
var _pbm_nx: Array = []             # slot -> Nx
var _pbm_ny: Array = []             # slot -> Ny
var _pbm_mutex := Mutex.new()       # guards the result handoff (_pbm_bytes[i]) between worker and main
var _pbm_mode: Array = []           # slot -> 0 band (bm_texels² → layer), 1 fine (fm_texels² → sub-page)
# FP_PLANET_MAP fine tier — always-resident whole-planet L8 map, 24 sub-page layers (6 faces × 2×2 quadrants).
var _fm_on := false
var _fm_texels := 0                 # PLANET_MAP_TEXELS (128)
var _fm_quad := 0                   # PLANET_MAP_QUAD (12); sub-page edge = quad·texels = 1536
var _fm_page := 0
var _fm_pages: Array = []           # 24 L8 sub-page staging Images (blit target)
var _fm_tex: Texture2DArray = null  # 24-layer GPU array (bound as fine_map)
var _fine_baked: Dictionary = {}    # fid -> true (baked into its sub-page)
var _fm_dirty: Dictionary = {}      # layer -> true (needs update_layer)
var _fm_epoch := 0
var _fm_upload_cd := 0
var _fm_cursor := 0
var _bm_bake_lc := PackedVector2Array()  # the in-progress facet's 4 lattice corners (computed once per facet)
var _bm_bake_nx := 0               # the in-progress facet's block count along s (round |lc1-lc0|)
var _bm_bake_ny := 0               # the in-progress facet's block count along t (round |lc3-lc0|)
var _bm_active_fid := -1           # the ACTIVE facet whose L8 staging image is retained on CPU (the design's ONE staging
var _bm_active_img: Image = null   #   layer, for incremental edit splats + a headless-readable band id surface)
var _bm_epoch := 0                  # bumped on any _bm_slots / reverse-map change → WorldManager pushes the new maps

# COSMOS MAIN-THREAD ORCHESTRATION TH1 (FP_TEX_BAKE_WORKER) — the per-frame bake COMPUTE moved onto the TH0 job-lane
# worker, so update() on MAIN only orchestrates + pays the update_layer commit. Single in-flight per baker (the
# far-ring contract): while a compute unit is on the worker, update() does nothing (holds), the lane's pump reaps it
# and runs the commit on main. The worker touches ONLY the preallocated staging Images (_pages/_cu_layers/_bm_bake_img)
# + its own resume ints (single-writer while in flight); every residency dict (_baked/_cu_slots/_bm_slots/_cu_dirty +
# epochs) is mutated ONLY on main at commit, so nothing is read+written across threads. Off ⇒ _worker_on false ⇒ the
# today-exact on-main path (_update_main), lane never touched. Requires FP_JOB_LANE (the lane must exist).
var _lane: JobLane = null           # the shared TH0 JobLane (set by WorldManager); null ⇒ on-main path
var _worker_on := false             # FP_TEX_BAKE_WORKER && _lane != null (the offload is live)
var _job_inflight := false          # a compute unit is dispatched onto the worker (single in-flight gate)
var _job_kind := ""                 # the in-flight unit's tier: "base" | "cu" | "bm"
var _job_base_fid := -1             # the in-flight base unit's facet (kind == "base")
var _job_base_shot := false         # V3 (FP_PAGES_SHOT): the in-flight base unit is a g1 shot re-bake (vs a g0 coverage bake)
var _cu_last_done := false          # the close-up compute slice just finished its facet (commit finalizes residency)
var _bm_last_done := false          # the band compute slice just finished its facet (commit uploads + finalizes)
var _main_bake_us := 0              # the bake work paid ON MAIN in the last update() (the G-TW-MAINCOST proof surface):
									#   on-main path = the whole compute; worker path = orchestration + submit only (~0)

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
	# COSMOS TEXTURED-LOD T1b: allocate the 6 L8 id pages (id 0 everywhere = un-baked). Only under FP_BLOCK_DETAIL →
	# zero id bytes with the flag off. bake_facet writes each texel's FarPalette.detail_pattern + 1 next to its colour.
	_bd_on = CubeSphere.FP_BLOCK_DETAIL
	if _bd_on:
		FarPalette.ensure_detail_ready()
		_id_pages.resize(6)
		for f in range(6):
			var idimg := Image.create(_page, _page, false, Image.FORMAT_L8)
			idimg.fill(Color(0.0, 0.0, 0.0, 1.0))    # id 0 = un-baked
			_id_pages[f] = idimg
	# COSMOS TEXTURED-LOD V3: arm the g0/g1 shot rebake. The baker only exists under FP_FACET_TEX (WorldManager
	# gated-construction), so _shot_on already satisfies the requires-FP_FACET_TEX rule. Pre-warm every static
	# SurfaceShot.surface_shot touches HERE on main (FarPalette/BlockCatalog lazy-init), so the TH1 worker never
	# races a first-touch init when a g1/close-up shot slice runs on the lane worker.
	_shot_on = CubeSphere.FP_PAGES_SHOT
	if _shot_on:
		FarPalette.ensure_ready()
		FarPalette.ensure_detail_ready()
		BlockCatalog.ensure_ready()
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
	# COSMOS TEXTURED-LOD U1 (§2U.1): allocate the BAND id map (BAND_LAYERS x BAND_TEXELS^2 L8, id 0 everywhere = un-baked)
	# and seed the free-layer pool + reverse maps. Requires FP_BLOCK_DETAIL (the band composites detail_map[id]) so _bm_on
	# implies _bd_on. Only under FP_BAND_BLOCK_MAP -> zero band bytes with the flag off. Built ONCE (all id 0 -> the shader's
	# band branch is skipped until a facet is baked resident); a completed bake only does a cheap update_layer.
	_bm_on = CubeSphere.FP_BAND_BLOCK_MAP and (_bd_on or CubeSphere.FP_SKIN_FLATCOLOR)
	# COSMOS TEXTURED-LOD §2V V2 (FP_BAND_SHOT): the band stores RG8 {block_id, shade} (the real shot incl trees) instead
	# of L8 {id}. Off ⇒ _bm_shot false ⇒ the L8 format + id-only bake below are BYTE-IDENTICAL to the U1 band.
	_bm_shot = CubeSphere.FP_BAND_SHOT and _bm_on
	# FP_SKIN_FLATCOLOR: bake the band as an L8 per-block COLOUR-INDEX map (tile-mean palette, incl trees) so the shell
	# shader flat-colours it (no detail pattern). Prewarm the palette + classifier on the MAIN thread here so the
	# offloaded band worker never races init (mirrors the shot prewarm). Mutually exclusive with the RG8 shot band.
	_bm_flat = CubeSphere.FP_SKIN_FLATCOLOR and _bm_on and not _bm_shot
	if _bm_flat:
		BlockCatalog.ensure_ready()
		FarPalette.ensure_ready()
		FarPalette.ensure_far_index_ready()
	if _bm_on:
		_bm_texels = CubeSphere.BAND_TEXELS
		_bm_facet.resize(CubeSphere.band_layers())
		_bm_n.resize(CubeSphere.band_layers())
		_bm_free.clear()
		var bimgs: Array[Image] = []
		for i in range(CubeSphere.band_layers()):
			var bimg := Image.create(_bm_texels, _bm_texels, false, _band_img_format())
			bimg.fill(Color(0.0, 0.0, 0.0, 1.0))   # id 0 = un-baked
			_bm_facet[i] = Vector2(-1.0, -1.0)
			_bm_n[i] = Vector2(0.0, 0.0)
			_bm_free.append(i)
			bimgs.append(bimg)
		_bm_tex = Texture2DArray.new()
		_bm_tex.create_from_images(bimgs)

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
	_bake_facet_pixels(fid)
	_baked[fid] = true

## COSMOS TEXTURED-LOD V3 (FP_PAGES_SHOT): the g1 entry — re-bake facet `fid`'s page as the REAL-shot box-downscale
## (tint × static-shade incl trees) in place, and mark it baked + shot. The synchronous twin of the g1 cursor unit,
## used by the gate + a direct upgrade. Does NOT upload — a caller batches _rebuild_texture()/_flush_base_uploads().
func bake_facet_shot(fid: int) -> void:
	_bake_facet_pixels(fid, true)
	_baked[fid] = true
	_shot_baked[fid] = true

## TH1: the PIXEL compute of bake_facet WITHOUT the `_baked[fid]` residency write — pure CPU (sample_columns +
## box-average set_pixel composite + id classify), writing ONLY into the facet's page/id staging Images. Worker-safe
## (the residency dict is mutated on main at commit, never here). bake_facet(=this + `_baked[fid]=true`) is the
## unchanged on-main entry; the worker base unit calls this and the commit sets `_baked`.
func _bake_facet_pixels(fid: int, shot := false) -> void:
	var d := _decode(fid)
	var face: int = d[0]
	var a: int = d[1]
	var b: int = d[2]
	# COSMOS TEXTURED-LOD V3 (FP_PAGES_SHOT): the colour source is the REAL shot (tint × static-shade incl trees) in g1
	# shot mode, else today's FarPalette biome colour (g0). `id_src` stays the UNshaded material colour so the T1b id map
	# keeps classifying the true material even under shot (shade is a scalar the id lookup must not see). In g0 mode there
	# is one source (fine) and the id classifies from the very same box-averaged colour → byte-identical to the shipped bake.
	var col_src: PackedColorArray
	var id_src: PackedColorArray
	if shot:
		var sh := sample_fine_shot(fid)     # [appearance = tint×shade, tint] over the same BAKE_SRC² fine grid
		col_src = sh[0]
		id_src = sh[1]
	else:
		col_src = sample_fine(fid)
		id_src = col_src
	var img: Image = _pages[face]
	var ox := a * BASE_TEXELS
	var oy := b * BASE_TEXELS
	var inv := 1.0 / float(DOWNS * DOWNS)
	var idimg: Image = _id_pages[face] if _bd_on else null
	for ty in range(BASE_TEXELS):
		for tx in range(BASE_TEXELS):
			var r := 0.0
			var g := 0.0
			var bl := 0.0
			for sy in range(DOWNS):
				var row := (ty * DOWNS + sy) * BAKE_SRC + tx * DOWNS
				for sx in range(DOWNS):
					var c: Color = col_src[row + sx]
					r += c.r
					g += c.g
					bl += c.b
			var avg := Color(r * inv, g * inv, bl * inv, 1.0)
			img.set_pixel(ox + tx, oy + ty, avg)
			# COSMOS TEXTURED-LOD T1b: classify this macro texel's material from its STORED (box-averaged) colour — the
			# same value color_for feeds the ring — and store id = FarPalette.detail_pattern + 1 (0 stays un-baked). A
			# uniform texel's average IS its exact palette colour (interior exact, G-BD-ID); a boundary picks the nearer
			# (§2R.6 D4). One classify per stored texel (not per fine sample) keeps the bake unit under G-FT-BUDGET.
			# V3: under shot the id classifies from the UNshaded tint mean (id_src), not the shaded colour page.
			if _bd_on:
				var id_col := avg
				if shot:
					var tr := 0.0
					var tg := 0.0
					var tb := 0.0
					for sy in range(DOWNS):
						var trow := (ty * DOWNS + sy) * BAKE_SRC + tx * DOWNS
						for sx in range(DOWNS):
							var tc: Color = id_src[trow + sx]
							tr += tc.r
							tg += tc.g
							tb += tc.b
					id_col = Color(tr * inv, tg * inv, tb * inv, 1.0)
				var id := FarPalette.detail_pattern(id_col) + 1
				var lv := float(id) / 255.0
				idimg.set_pixel(ox + tx, oy + ty, Color(lv, lv, lv, 1.0))

## COSMOS TEXTURED-LOD V3 (§2V.1): the fine BAKE_SRC×BAKE_SRC grid of the REAL SHOT per column — the near daylight
## material's own per-block appearance a top-down photo would show (§2V.0 (B)), which the page box-downscales. Returns
## [appearance, tint] PackedColorArrays over the SAME lattice grid sample_fine samples (same corner mapping + rounding),
## so g0↔g1 differ ONLY in the colour source, never the footprint. appearance = tint × static-shade (sun-independent:
## the sun shade is applied live by the shell shader, V1); tint is the un-shaded material colour for the id classify.
## Pure: SurfaceShot.surface_shot is deterministic (TerrainConfig/TreeGen/FarPalette/BlockCatalog statics + a facet-homed
## GenCtx), so it is worker-safe (the TH1 base/close-up shot units run this on the lane worker). Public so the gate
## re-samples the SAME grid the page box-averages (G-VP-DOWNSCALE) — two calls are byte-identical.
func sample_fine_shot(fid: int) -> Array:
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	var pcache = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else null
	var appear := PackedColorArray()
	appear.resize(BAKE_SRC * BAKE_SRC)
	var tint := PackedColorArray()
	tint.resize(BAKE_SRC * BAKE_SRC)
	for fj in range(BAKE_SRC):
		var t := (float(fj) + 0.5) / float(BAKE_SRC)
		var row := fj * BAKE_SRC
		for fi in range(BAKE_SRC):
			var s := (float(fi) + 0.5) / float(BAKE_SRC)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var rec := SurfaceShot.surface_shot(fid, lx, lz, pcache)
			var tc: Color = rec["tint"]
			var sh: float = rec["shade"]
			appear[row + fi] = Color(tc.r * sh, tc.g * sh, tc.b * sh, 1.0)
			tint[row + fi] = Color(tc.r, tc.g, tc.b, 1.0)
	return [appear, tint]

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
	_rebuild_id_texture()

## COSMOS TEXTURED-LOD T1b: (re)build the 6-layer L8 id map (NEAREST, no mips, no premultiply — id is not colour). No-op
## off FP_BLOCK_DETAIL. Built once after the prewarm batch; incremental faces ride _flush_base_uploads' update_layer.
func _rebuild_id_texture() -> void:
	if not _bd_on:
		return
	var imgs: Array[Image] = []
	for f in range(6):
		imgs.append(_id_pages[f])
	if _id_tex == null:
		_id_tex = Texture2DArray.new()
		_id_tex.create_from_images(imgs)
	else:
		for f in range(6):
			_id_tex.update_layer(imgs[f], f)

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
##
## TH1 (FP_TEX_BAKE_WORKER): when the offload is live, this dispatches to _update_worker — the heavy compute leaves
## the frame onto the job-lane worker and main only orchestrates + commits. Off ⇒ the today-exact on-main path below.
## COSMOS PLANET-LOD-CONFIG P0 (§2.4): freeze the §2V page bakes while the orbit megablock tier owns the disc — the
## user's "bake pop-in at orbit" complaint. Frozen ⇒ update() is a no-op (no sample_columns page rebakes), so orbiting
## adds ZERO bake latency; the far ring's skin samplers are already unbound (set_skin_active) so nothing draws it.
## Resumed on descent. Untouched with FP_BLOCK_LOD_ORBIT off (never called) ⇒ byte-identical.
var _frozen := false
func set_frozen(frozen: bool) -> void:
	_frozen = frozen

func update(emit_axis: Array, offsurface: bool, budget_ms: float, active_fid := -1, cam_dist := -1.0) -> void:
	if _frozen:
		return
	# FP_SKIN_FLATCOLOR multi-core band: refresh the residency want on main, then reap/dispatch the parallel full-facet
	# bakes across all cores. The band is handled ENTIRELY here — the single-in-flight paths below skip it (not _pbm_on).
	if _pbm_on:
		if CubeSphere.FP_SKIN_SSE and cam_dist > 0.0 and _bm_on and active_fid >= 0:
			_recompute_band_want_sse(active_fid, emit_axis, cam_dist)
		_update_band_parallel(emit_axis)
	if _worker_on:
		_update_worker(emit_axis, offsurface, budget_ms, active_fid, cam_dist)
	else:
		_update_main(emit_axis, offsurface, budget_ms, active_fid, cam_dist)

## The on-main per-frame bake driver — the shipped path (FP_TEX_BAKE_WORKER off), byte-untouched by TH1.
func _update_main(emit_axis: Array, offsurface: bool, budget_ms: float, active_fid := -1, cam_dist := -1.0) -> void:
	var start := Time.get_ticks_usec()
	var budget_us := int(budget_ms * 1000.0)
	# COSMOS TEXTURED-LOD V4 (§2V.2, FP_SKIN_SSE): the screen-space MONOTONE promotion law. When on (and cam_dist is a real
	# scale-correct distance from the body centre), BOTH the band and close-up want-sets are driven by each facet's on-screen
	# block size (per-facet camera distance) — NOT by the flight regime — so a descent only ever INCREASES fidelity (no
	# regime evict-all dumping the close-up tier at surface entry). Largest-deficit-first = the finer BAND tier is served
	# before the CLOSE-UP tier under the shared budget; both drain nearest-first (check-before-slice ⇒ bounded worst frame).
	# Degraded fallback (cam_dist ≤ 0, e.g. the shell driver never armed) ⇒ the shipped regime path below (safe, monotone-
	# neutral). See _recompute_want_sse / _recompute_band_want_sse. Absorbs T2: on-surface band membership is now "screen
	# demands it" (the nadir cap), not "ring-1 on surface".
	if CubeSphere.FP_SKIN_SSE and cam_dist > 0.0:
		if _bm_on and active_fid >= 0:
			_recompute_band_want_sse(active_fid, emit_axis, cam_dist)
			_bake_band_budgeted(start, budget_us)          # finest tier (largest deficit) first
		if _cu_on:
			_recompute_want_sse(emit_axis, cam_dist)       # NO regime gate, NO evict-all
			_bake_closeup_budgeted(start, budget_us)       # whatever budget the band left
		_bake_base_progressive(start, budget_us, emit_axis)
		_flush_base_uploads()
		_flush_closeup_uploads()
		var spent_sse := Time.get_ticks_usec() - start
		_budget_spent_us = spent_sse
		_worst_frame_us = maxi(_worst_frame_us, spent_sse)
		_main_bake_us = spent_sse
		return
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
	# COSMOS TEXTURED-LOD U1 (§2U.1): drive the near-far BAND — refresh residency to active ∪ ring-1 (evict on ring exit),
	# then bake missing band facets ROW-SLICED under the SHARED budget (check-before-slice, never mid-slice → bounded like
	# the close-up tier). No-op off FP_BAND_BLOCK_MAP or with no active facet. Band gets the budget FIRST (it is the near
	# aesthetic the user is looking at); progressive base coverage below spends whatever remains.
	# FP_SKIN_FLATCOLOR + FP_SKIN_SSE: the SSE path (in _update_main's cam_dist>0 branch) OWNS the band residency
	# (screen-space over the whole 180-facet disc). This fallback ring-1 recompute must NOT run for it — a TRANSIENT
	# cam_dist≤0 on a facet crossing would otherwise shrink the disc to ring-1 (the visible fly-time churn / reset).
	# Keep baking the already-committed SSE want (no recompute = no eviction) so the disc just holds + finishes.
	if _bm_on and active_fid >= 0 and not (CubeSphere.FP_SKIN_SSE and CubeSphere.FP_SKIN_FLATCOLOR):
		_recompute_band_want(active_fid)
		_bake_band_budgeted(start, budget_us)
	elif _bm_on and CubeSphere.FP_SKIN_SSE and CubeSphere.FP_SKIN_FLATCOLOR:
		_bake_band_budgeted(start, budget_us)   # hold the disc; keep filling it even while cam_dist is transiently ≤ 0
	# COSMOS TEXTURED-LOD V3 (FP_PAGES_SHOT): the g1 background cursor — re-bake already-covered (g0) facets to the REAL
	# shot, nearest-emit-axis first then a global sweep (whole-planet convergence). Runs BEFORE g0 coverage so it is not
	# starved by the thousands of un-covered facets: the two generations ping-pong — coverage adds a fast g0 facet, the
	# next cursor pass upgrades it to the shot (a covered facet is always a soft picture, never flat biome colour). A
	# whole-facet shot bake is heavy in GDScript (F2 risk); production runs it OFF-MAIN on the TH1 worker (the compute
	# leaves the frame), and the flag is default-off pending the C++ surface_shot mirror. No-op off _shot_on ⇒ the page
	# bake stays the g0 palette colour (boot + coverage byte-identical). Check-before-each like coverage.
	if _shot_on:
		_bake_shot_progressive(start, budget_us, emit_axis)
	# Phase 2: progressive BASE coverage (g0 palette) with the remaining budget (whole-facet units, check-before-each).
	_bake_base_progressive(start, budget_us, emit_axis)
	# Bounded incremental uploads (main-thread RenderingServer touch): ≤ a few pages/layers per update.
	_flush_base_uploads()
	_flush_closeup_uploads()
	var spent := Time.get_ticks_usec() - start
	_budget_spent_us = spent
	_worst_frame_us = maxi(_worst_frame_us, spent)
	_main_bake_us = spent               # on-main path: the WHOLE bake compute was paid on main (the G-TW-MAINCOST baseline)

# --- TH1: the worker-offload per-frame driver (FP_TEX_BAKE_WORKER) -------------------------------

## The MAIN-thread half of the offload: orchestrate (cheap, pure dot-scan want/evict — same as _update_main), pick ONE
## bake UNIT, freeze it and dispatch its COMPUTE to the job-lane worker; the worker fills the preallocated staging
## Image, and the lane's commit (main) pays only the update_layer + the residency bookkeeping. Single in-flight: while
## a unit is on the worker, this does nothing (holds) — the pump reaps + commits it, then the next update picks the
## next unit. So main pays ~0 for compute; coverage fills one unit per round-trip (matching today's web throughput,
## which already managed <1 heavy unit per frame under the budget), with NO frame stall.
func _update_worker(emit_axis: Array, offsurface: bool, budget_ms: float, active_fid := -1, cam_dist := -1.0) -> void:
	var start := Time.get_ticks_usec()
	if not _job_inflight:
		# --- MAIN orchestration (identical want/evict logic as _update_main; cheap pure dot scans) ---
		# COSMOS TEXTURED-LOD V4 (§2V.2): the SSE monotone law drives the want-sets when on + cam_dist known (NO evict-all);
		# else the shipped regime-keyed orchestration below. _select_worker_unit's close-up>band>base priority is unchanged.
		if CubeSphere.FP_SKIN_SSE and cam_dist > 0.0:
			if _bm_on and active_fid >= 0 and not _pbm_on:
				_recompute_band_want_sse(active_fid, emit_axis, cam_dist)
			if _cu_on:
				_recompute_want_sse(emit_axis, cam_dist)
		else:
			if _cu_on and offsurface:
				_recompute_want(emit_axis)
			elif _cu_on and not _cu_want.is_empty():
				_evict_all_closeup()
			if _bm_on and active_fid >= 0 and not _pbm_on:
				_recompute_band_want(active_fid)
		# --- pick ONE compute unit (priority: visible close-up > near band > progressive base), freeze + dispatch ---
		if _select_worker_unit(offsurface, emit_axis, active_fid):
			_job_inflight = true
			_lane.submit(JobLane.PRIORITY_TEXTURE,
				Callable(self, "_worker_compute_unit"), Callable(self, "_worker_commit_unit"), "tex-" + _job_kind)
	var spent := Time.get_ticks_usec() - start
	_budget_spent_us = spent
	_main_bake_us = spent               # worker path: main paid ONLY orchestration + submit — the compute left the frame
	_worst_frame_us = maxi(_worst_frame_us, spent)

## Choose + BEGIN the next compute unit; sets _job_kind and returns true if there is work. Mirrors the on-main priority
## (close-up when off-surface, then band, then progressive base). Begin state (staging Image, lattice corners, resume
## row) is set up on MAIN here; only the pixel fill runs on the worker. Continues an in-progress multi-slice facet.
func _select_worker_unit(offsurface: bool, emit_axis: Array, active_fid: int) -> bool:
	# Close-up (the crisp win the player is looking at) first, when off-surface — or, under the V4 screen-space law
	# (FP_SKIN_SSE), whenever the SSE recompute has admitted close-up demand (a non-empty want-set), regardless of regime.
	if _cu_on and (offsurface or (CubeSphere.FP_SKIN_SSE and not _cu_want.is_empty())):
		if _cu_bake_fid >= 0:
			_job_kind = "cu"; return true            # continue the in-progress close-up facet
		var cf := _next_want_to_bake()
		if cf >= 0 and _begin_closeup_bake(cf):
			_job_kind = "cu"; return true
	# Near-far band next — SKIPPED when the multi-core parallel band bake owns it (_pbm_on).
	if _bm_on and active_fid >= 0 and not _pbm_on:
		if _bm_bake_fid >= 0:
			_job_kind = "bm"; return true            # continue the in-progress band facet
		var bf := _next_band_to_bake()
		if bf >= 0 and _begin_band_bake(bf):
			_job_kind = "bm"; return true
	# V3 (FP_PAGES_SHOT): the g1 shot rebake — upgrade a covered-but-un-shot facet to the real shot (nearest-axis first).
	# Runs BEFORE g0 coverage (same order as the on-main cursor): the two generations ping-pong across worker round-trips
	# — when the upgrade queue empties, coverage below adds a g0 facet, which the next round upgrades. Off _shot_on ⇒
	# skipped ⇒ coverage-only (byte-identical). The heavy shot compute runs on the lane worker (off-main) here.
	if _shot_on and _shot_baked.size() < _baked.size():
		var sf := _next_shot_fid(emit_axis)
		if sf >= 0:
			_job_base_fid = sf; _job_base_shot = true; _job_kind = "base"; return true
	# Progressive base coverage (g0 palette) last.
	if _baked.size() < _base_all:
		var pf := _next_base_fid(emit_axis)
		if pf >= 0:
			_job_base_fid = pf; _job_base_shot = false; _job_kind = "base"; return true
	return false

## WORKER THREAD: run the in-flight unit's PIXEL compute into its staging Image only (NO RenderingServer / tree touch,
## NO residency-dict write — G-TW-NOTREE). For base: composite + premultiply + mips on the page. For close-up/band:
## one row-slice. All shared bookkeeping is deferred to _worker_commit_unit on main.
func _worker_compute_unit() -> void:
	match _job_kind:
		"base":
			_bake_facet_pixels(_job_base_fid, _job_base_shot)   # V3: _job_base_shot ⇒ g1 real-shot re-bake (worker-safe, pure)
			var face := face_of(_job_base_fid)
			var img: Image = _pages[face]
			img.premultiply_alpha()               # coverage-correct mips (same as _flush_base_uploads); idempotent on a∈{0,1}
			img.generate_mipmaps()
		"cu":
			_cu_compute_slice()
		"bm":
			_bm_compute_slice()

## MAIN THREAD (lane commit): pay ONLY the GPU upload + finalize the residency bookkeeping single-writer on main, then
## release the in-flight gate so the next update picks the next unit.
func _worker_commit_unit() -> void:
	match _job_kind:
		"base":
			_commit_base_facet(_job_base_fid)
			if _job_base_shot:
				_shot_baked[_job_base_fid] = true   # V3: mark g1 shot coverage (single-writer on main)
		"cu":
			_cu_commit_slice()
			_flush_closeup_uploads()
		"bm":
			_bm_commit_slice()                    # the band's update_layer + reverse-map live here (main only)
	_job_kind = ""
	_job_base_fid = -1
	_job_base_shot = false
	_job_inflight = false

## MAIN: upload facet `fid`'s base page (premultiply + mips already done on the worker) + mark it baked. Upload-only —
## the compute never touched the GPU. Lazily builds the array only if prewarm never ran (headless edge; GPU on main).
func _commit_base_facet(fid: int) -> void:
	var face := face_of(fid)
	_baked[fid] = true                            # residency dict mutated ONLY on main (single-writer)
	if _tex == null:
		_rebuild_texture()                        # first coverage bake before any prewarm — build the whole array (main)
		return
	_tex.update_layer(_pages[face], face)
	if _bd_on:
		if _id_tex == null:
			_rebuild_id_texture()
		else:
			_id_tex.update_layer(_id_pages[face], face)

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

# --- V3: the g1 shot-rebake cursor (FP_PAGES_SHOT) -----------------------------------------------

## Re-bake already-covered (g0) facets to the REAL shot until the budget line. Priority mirrors coverage: the covered
## facet NEAREST the emit axis first (the shot upgrade grows where the player looks), then a global cursor sweep so the
## WHOLE planet converges to shot coverage. Whole-facet units; the budget is checked BEFORE each (never mid-unit → the
## worst frame stays budget + one unit). A shot re-bake overwrites the facet's page rect in place (no new bytes) and
## dirties its face for the shared incremental upload. Runs ONLY after g0 coverage, so it never delays first-appearance.
func _bake_shot_progressive(start: int, budget_us: int, axis: Array) -> void:
	if _shot_baked.size() >= _base_all:
		return
	while _shot_baked.size() < _base_all:
		if Time.get_ticks_usec() - start >= budget_us:
			return                          # budget line reached → resume next update (CHECK-BEFORE, never mid-unit)
		var fid := _next_shot_fid(axis)
		if fid < 0:
			return                          # no covered-but-un-shot facet available this update
		_bake_facet_pixels(fid, true)       # g1: real-shot box-downscale into the same page rect
		_shot_baked[fid] = true
		_base_dirty[face_of(fid)] = true

## The next facet to shot-rebake: a facet that IS g0-covered (`_baked`) but NOT yet shot (`_shot_baked`), preferring the
## largest dot to `axis` (nearest the sub-camera point), else the global cursor sweep. Requiring `_baked` first keeps the
## g0 coverage generation ahead of the g1 upgrade (boot-safe ordering). Returns -1 when every covered facet is shot.
func _next_shot_fid(axis: Array) -> int:
	var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
	var best := -1
	var best_dot := -2.0
	if ax * ax + ay * ay + az * az > 0.5:
		for fid in range(_base_all):
			if _shot_baked.has(fid) or not _baked.has(fid):
				continue
			var cd := _centre_pack[fid]
			var d := cd.x * ax + cd.y * ay + cd.z * az
			if d > best_dot:
				best_dot = d; best = fid
		if best >= 0:
			return best
	for _i in range(_base_all):
		var fid := _shot_cursor
		_shot_cursor = (_shot_cursor + 1) % _base_all
		if _baked.has(fid) and not _shot_baked.has(fid):
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
		# COSMOS TEXTURED-LOD T1b: re-upload the same face's id page (baked in lockstep with its colour). Lazily create
		# the id array on the first flush if the prewarm never ran (mirrors the colour _rebuild_texture fallback above).
		if _bd_on:
			if _id_tex == null:
				_rebuild_id_texture()
			else:
				_id_tex.update_layer(_id_pages[int(face)], int(face))
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

## COSMOS TEXTURED-LOD V4 (§2V.2, FP_SKIN_SSE): the SCREEN-SPACE close-up want-set — the monotone replacement for the
## regime/angular-cap _recompute_want. `cam_dist` is the camera's scale-correct distance from the body centre; `axis` is
## the sub-camera unit direction, so the camera in ABSOLUTE mesh space is axis·cam_dist. A facet whose blocks exceed the
## close-up screen threshold — i.e. whose per-facet camera distance is within CLOSEUP_FAR, on the near hemisphere — is
## wanted, NEAREST first, capped to CLOSEUP_MAX (== the layer pool, so the cap itself frees layers for closer facets).
## HYSTERESIS: a facet already RESIDENT is held to the wider CLOSEUP_FAR·SSE_HYST release distance, so one the player is
## approaching never churns at the boundary. NO regime gate, NO evict-all → as cam_dist shrinks the want only GROWS toward
## the camera and the nearest (nadir) facet is never the LRU victim ⇒ its resolved tier is monotone non-decreasing.
func _recompute_want_sse(axis: Array, cam_dist: float) -> void:
	var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
	if ax * ax + ay * ay + az * az < 0.5:
		return                                  # degenerate axis (camera at centre) — hold the last want-set
	var r := FacetAtlas.R_BLOCKS
	var camx := ax * cam_dist; var camy := ay * cam_dist; var camz := az * cam_dist
	var promote := CubeSphere.CLOSEUP_FAR
	var release := CubeSphere.CLOSEUP_FAR * CubeSphere.SSE_HYST
	var cand := []                              # [dist, fid] — near-hemisphere facets within the (hysteretic) threshold
	for fid in range(_base_all):
		var cd := _centre_pack[fid]
		if cd.x * ax + cd.y * ay + cd.z * az <= 0.0:
			continue                            # far hemisphere (behind the limb) — never a close-up candidate
		var dx := camx - cd.x * r; var dy := camy - cd.y * r; var dz := camz - cd.z * r
		var dist := sqrt(dx * dx + dy * dy + dz * dz)
		var thr: float = release if _cu_slots.has(fid) else promote
		if dist <= thr:
			cand.append([dist, fid])
	cand.sort()                                 # nearest (smallest dist) first
	var want := {}
	var n := mini(cand.size(), CubeSphere.CLOSEUP_MAX)
	for i in range(n):
		# Store a POSITIVE closeness (larger = nearer) so _next_want_to_bake's shared best-score floor (which the angular
		# path seeds at a dot ≥ −1) still selects the nearest facet; a raw −dist would sit below that floor and be skipped.
		want[int(cand[i][1])] = 1.0 / (1.0 + float(cand[i][0]))
	# Evict residents that fell out of the capped want (past release, or bumped by CLOSEUP_MAX closer facets). NEVER an
	# evict-all: only genuinely-farther tiles leave, so the approached facet keeps its layer (monotone).
	for fid in _cu_slots.keys():
		if not want.has(int(fid)):
			_evict_closeup(int(fid))
	# Abandon the in-progress bake only if its facet left the want (its layer returns to the pool).
	if _cu_bake_fid >= 0 and not want.has(_cu_bake_fid):
		if not _cu_free.has(_cu_bake_layer):
			_cu_free.append(_cu_bake_layer)
		_cu_bake_fid = -1; _cu_bake_layer = -1; _cu_bake_img = null
	_cu_want = want
	_cu_want_axis = [ax, ay, az]

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

## On-main close-up slice = compute + commit inline (byte-untouched shipped path). TH1 splits these so the compute runs
## on the worker (pixels only) and the commit (residency + upload) runs on main — same ops, same order, same bytes.
func _bake_closeup_slice() -> void:
	_cu_compute_slice()
	_cu_commit_slice()

## PIXEL compute (worker-safe): sample CLOSEUP_SLICE_ROWS more rows of the in-progress facet's 128² fine grid (one
## sample_columns call) and write the top-block colours straight (alpha 1) into the staging layer. On the last row,
## premultiply + mips (coverage-correct like the base page). Writes ONLY the staging Image + resume ints — NO residency
## dict, NO RenderingServer. Sets _cu_last_done so the commit knows to finalize.
func _cu_compute_slice() -> void:
	_cu_last_done = false
	var n := _cu_texels
	var r0 := _cu_bake_row
	var r1 := mini(r0 + CubeSphere.CLOSEUP_SLICE_ROWS, n)
	var rows := r1 - r0
	var lc := _cu_bake_lc
	var img: Image = _cu_bake_img
	if _shot_on:
		# COSMOS TEXTURED-LOD V3 (FP_PAGES_SHOT): each close-up texel is the REAL shot at its column (1:1 here, no
		# box-average) — tint × static-shade incl trees (§2V.1). Sun shading stays live in the shell shader (V1), so
		# only the static cues are baked. SurfaceShot is pure/deterministic ⇒ worker-safe (this runs on the TH1 lane).
		var pcache = TerrainConfig.GenCtx.new(0, _cu_bake_fid) if CubeSphere.FACETED else null
		for rj in range(rows):
			var fj := r0 + rj
			var t := (float(fj) + 0.5) / float(n)
			for fi in range(n):
				var s := (float(fi) + 0.5) / float(n)
				var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
				var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
				var rec := SurfaceShot.surface_shot(_cu_bake_fid, lx, lz, pcache)
				var tc: Color = rec["tint"]
				var sh: float = rec["shade"]
				img.set_pixel(fi, fj, Color(tc.r * sh, tc.g * sh, tc.b * sh, 1.0))
	else:
		var packed := PackedInt64Array()
		packed.resize(rows * n)
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
		for rj in range(rows):
			var fj := r0 + rj
			var base := rj * n
			for fi in range(n):
				var c: Color = cols[base + fi]
				img.set_pixel(fi, fj, Color(c.r, c.g, c.b, 1.0))
	_cu_bake_row = r1
	if r1 < n:
		return                              # more slices next update
	img.premultiply_alpha()
	img.generate_mipmaps()
	_cu_last_done = true

## MAIN commit: if the facet just completed, mark the layer dirty (upload), make it RESIDENT (_cu_slots[fid]=layer),
## record its (a,b) reverse-map + bump the epoch. Every residency-dict write is here (single-writer on main).
func _cu_commit_slice() -> void:
	if not _cu_last_done:
		return
	_cu_last_done = false
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

# --- U1: the near-far BAND real-block id map (§2U.1) ---------------------------------------------

## Recompute the band residency (active ∪ ring-1, capped to BAND_LAYERS) and EVICT residents that left the ring. The
## want-set changes only on a facet crossing, so this is skipped while `active_fid` is unchanged — the standing camera
## re-runs nothing. Eviction frees the layer back to the pool (a facet leaving the band falls back to the §2R tiled
## detail path — same catalog hues, coarser arrangement, at distances where a block is ≤ 2 px). Bumps the epoch.
func _recompute_band_want(active_fid: int) -> void:
	if active_fid == _bm_want_active and not _bm_want.is_empty():
		return
	_bm_want_active = active_fid
	var want := {}
	var ring := TierPlace.ring1(active_fid)          # [active, 4 seam, diagonals…]; take the nearest BAND_LAYERS
	for i in range(ring.size()):
		if want.size() >= CubeSphere.band_layers():
			break
		want[int(ring[i])] = true
	# Evict residents no longer in the band ring (the evict-only-on-ring-exit invariant the gate checks).
	for fid in _bm_slots.keys():
		if not want.has(int(fid)):
			_evict_band(int(fid))
	# If the in-progress bake's facet left the ring, abandon it (its layer returns to the pool).
	if _bm_bake_fid >= 0 and not want.has(_bm_bake_fid):
		if not _bm_free.has(_bm_bake_layer):
			_bm_free.append(_bm_bake_layer)
		_bm_bake_fid = -1; _bm_bake_layer = -1; _bm_bake_img = null
	_bm_want = want

## COSMOS TEXTURED-LOD V4 (§2V.2, FP_SKIN_SSE): the SCREEN-SPACE band want-set — the monotone replacement for the
## active∪ring-1 _recompute_band_want. The BAND is the FINEST tier (real per-block ids, blocks ≥ ~2 px), so it is wanted
## for facets whose per-facet camera distance falls within CLOSEUP_NEAR (where the close-up tier saturates and the band
## takes over), NEAREST first, capped to BAND_LAYERS. This is the T2 absorption: on-surface the nadir facet has the
## SMALLEST distance so it always wins a band slot (no special-case floor needed); at orbit its blocks are < 2 px so it
## stays base. HYSTERESIS via CLOSEUP_NEAR·SSE_HYST for residents; evict-only-when-farther (never the nearest/nadir facet)
## ⇒ as cam_dist shrinks the nadir facet's band residency is monotone. `active_fid` only tie-breaks the bake order.
func _recompute_band_want_sse(active_fid: int, axis: Array, cam_dist: float) -> void:
	var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
	if ax * ax + ay * ay + az * az < 0.5:
		_recompute_band_want(active_fid)        # degenerate axis — fall back to the ring residency (safe)
		return
	var r := FacetAtlas.R_BLOCKS
	var camx := ax * cam_dist; var camy := ay * cam_dist; var camz := az * cam_dist
	# FP_SKIN_FLATCOLOR wants the per-block map out to the visible disc (up to BAND_LAYERS nearest); the shipped
	# close-up reach (CLOSEUP_NEAR) only feeds ~ring-1. BAND_LAYERS still self-caps the nearest-first want.
	var promote: float = CubeSphere.BAND_PROMOTE_DIST if CubeSphere.FP_SKIN_FLATCOLOR else CubeSphere.CLOSEUP_NEAR
	var release := promote * CubeSphere.SSE_HYST
	var cand := []                              # [dist, fid]
	for fid in range(_base_all):
		var cd := _centre_pack[fid]
		if cd.x * ax + cd.y * ay + cd.z * az <= 0.0:
			continue                            # far hemisphere (behind the limb) — never a band candidate
		var dx := camx - cd.x * r; var dy := camy - cd.y * r; var dz := camz - cd.z * r
		var dist := sqrt(dx * dx + dy * dy + dz * dz)
		var thr: float = release if _bm_slots.has(fid) else promote
		if dist <= thr:
			cand.append([dist, fid])
	cand.sort()                                 # nearest first → the capped want is the BAND_LAYERS nearest facets
	var want := {}
	var n := mini(cand.size(), CubeSphere.band_layers())
	for i in range(n):
		want[int(cand[i][1])] = true
	# FP_SKIN_FLATCOLOR robustness: a TRANSIENT empty want (a bad axis/cam frame on a crossing) must NOT evict the whole
	# resident disc — hold it and let the next valid frame reconcile. (A genuine high-orbit empty just keeps the bounded
	# band resident a little longer; it is sub-pixel there anyway.)
	if want.is_empty() and CubeSphere.FP_SKIN_FLATCOLOR and not _bm_slots.is_empty():
		_bm_want_active = active_fid
		return
	# Evict residents that fell out of the capped want (never the active/approached facet — it is always nearest).
	for fid in _bm_slots.keys():
		if not want.has(int(fid)):
			_evict_band(int(fid))
	if _bm_bake_fid >= 0 and not want.has(_bm_bake_fid):
		if not _bm_free.has(_bm_bake_layer):
			_bm_free.append(_bm_bake_layer)
		_bm_bake_fid = -1; _bm_bake_layer = -1; _bm_bake_img = null
	_bm_want = want
	_bm_want_active = active_fid

## Bake band-but-not-resident facets (active first, then ring order), ROW-SLICED, until the budget line. Continues an
## in-progress facet across updates. A facet needs a free layer to start; if none is free (all in-ring residents) it is
## skipped (stays on the tiled detail path) — NEVER evicts an in-ring facet. Check-before-slice ⇒ bounded worst frame.
func _bake_band_budgeted(start: int, budget_us: int) -> void:
	while Time.get_ticks_usec() - start < budget_us:   # CHECK-BEFORE each slice (never mid-slice)
		if _bm_bake_fid < 0:
			var fid := _next_band_to_bake()
			if fid < 0:
				return                      # band fully resident/queued this ring
			if not _begin_band_bake(fid):
				return                      # no free layer (all in-ring resident) — leave it on the tiled path
		_bake_band_slice()

## The next wanted band facet that is neither resident nor already baking (active preferred, then ring order). -1 when done.
func _next_band_to_bake() -> int:
	if _bm_want.has(_bm_want_active) and not _bm_slots.has(_bm_want_active) and _bm_want_active != _bm_bake_fid:
		return _bm_want_active
	for fid in _bm_want.keys():
		var f := int(fid)
		if not _bm_slots.has(f) and f != _bm_bake_fid:
			return f
	return -1

## Acquire a free layer for `fid` and start its row-sliced band bake. Computes the facet's 4 lattice corners (the SAME
## mapping sample_fine uses) + its per-axis block counts Nx,Ny (round of the core edge, ≤ BAND_TEXELS). Returns false if
## no layer is free (every layer is an in-ring resident) — `fid` then stays on the tiled detail path this ring.
func _begin_band_bake(fid: int) -> bool:
	if _bm_free.is_empty():
		return false
	var layer := int(_bm_free.pop_back())
	_bm_bake_fid = fid
	_bm_bake_layer = layer
	_bm_bake_row = 0
	var img: Image = Image.create(_bm_texels, _bm_texels, false, _band_img_format())
	img.fill(Color(0.0, 0.0, 0.0, 1.0))     # id 0 = un-baked until rows fill in (RG8 under shot: shade 0 too, unread while id 0)
	_bm_bake_img = img
	if _bm_flat:                            # FP_SKIN_FLATCOLOR: the byte staging buffer the slices fill (id 0 = un-baked)
		_bm_bake_bytes.resize(_bm_texels * _bm_texels)
		_bm_bake_bytes.fill(0)
	_bm_bake_lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		_bm_bake_lc[ci] = Vector2(float(l[0]), float(l[2]))
	# Core facet block counts: |lc1-lc0| along s (UV.x), |lc3-lc0| along t (UV.y). Clamp to [1, BAND_TEXELS] so 1 texel
	# maps to ~1 lattice block and the map never over-runs its 512 edge (the DOMAIN bbox can exceed 512; the param edge
	# does not). This is the shader's band_n[slot] (block-frequency for both the id lookup and the intra-block UV).
	_bm_bake_nx = clampi(int(round((_bm_bake_lc[1] - _bm_bake_lc[0]).length())), 1, _bm_texels)
	_bm_bake_ny = clampi(int(round((_bm_bake_lc[3] - _bm_bake_lc[0]).length())), 1, _bm_texels)
	return true

## On-main band slice = compute + commit inline (byte-untouched shipped path). TH1 splits these so the id compute runs
## on the worker (staging Image only) and the commit (update_layer + reverse-map) runs on main — same bytes, and the
## update_layer moves from mid-slice to the commit (observationally identical: nothing reads the GPU layer between).
func _bake_band_slice() -> void:
	_bm_compute_slice()
	_bm_commit_slice()

## PIXEL compute (worker-safe): sample BAND_SLICE_ROWS more block-rows (by) of the in-progress facet's Nx×Ny param grid
## (ONE sample_columns call) and write each column's REAL top-block material id (FarPalette.detail_pattern+1 — no
## box-average) into the staging layer. Writes ONLY the staging Image + resume ints — NO update_layer, NO residency
## dict, NO RenderingServer. Sets _bm_last_done so the commit knows to upload + finalize.
func _bm_compute_slice() -> void:
	_bm_last_done = false
	var nx := _bm_bake_nx
	var ny := _bm_bake_ny
	var r0 := _bm_bake_row
	var r1 := mini(r0 + CubeSphere.BAND_SLICE_ROWS, ny)
	var rows := r1 - r0
	var lc := _bm_bake_lc
	if _bm_shot:
		# COSMOS TEXTURED-LOD §2V V2 (FP_BAND_SHOT): write the REAL top-down SHOT — R = surface_shot.block_id (the exposed
		# top block INCLUDING TreeGen decorations, so a tree column reads its canopy id, not the terrain beneath), G = the
		# sun-independent analytic shade byte. One SurfaceShot.surface_shot call per column (pure + facet-scoped via a fresh
		# per-slice GenCtx so terrain + trees resolve on THIS facet — no _active_facet read on the worker). The C++ sampler
		# is not consulted: surface_shot IS the id/tree derivation (no re-derivation here). Memo bounded to this slice.
		_bm_compute_slice_shot(r0, r1, nx, ny, lc)
	elif _bm_flat:
		_bm_compute_slice_flat(r0, r1, nx, ny, lc)
	else:
		var packed := PackedInt64Array()
		packed.resize(rows * nx)
		for rj in range(rows):
			var by := r0 + rj
			var t := (float(by) + 0.5) / float(ny)
			var base := rj * nx
			for bx in range(nx):
				var s := (float(bx) + 0.5) / float(nx)
				var lx := _bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)
				var lz := _bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)
				packed[base + bx] = _pack_xz(int(round(lx)), int(round(lz)))
		var res: Dictionary = _sampler.call(_bm_bake_fid, packed)
		var cols: PackedColorArray = res["colors"]
		var img: Image = _bm_bake_img
		for rj in range(rows):
			var by := r0 + rj
			var base := rj * nx
			for bx in range(nx):
				var id := FarPalette.detail_pattern(cols[base + bx]) + 1
				var lv := float(id) / 255.0
				img.set_pixel(bx, by, Color(lv, lv, lv, 1.0))
	_bm_bake_row = r1
	if r1 < ny:
		return                              # more slices next update
	_bm_last_done = true

## COSMOS TEXTURED-LOD §2V V2 worker-safe SHOT compute for rows [r0,r1): each column's REAL top-down record from
## SurfaceShot.surface_shot (block_id incl trees + sun-independent shade) into the RG8 staging layer (R=id, G=shade).
## A FRESH per-slice GenCtx homes every terrain/tree query on _bm_bake_fid (a captured facet VALUE — never the mutable
## _active_facet global) so the worker is race-free; its memo is bounded to this slice and released on return.
func _bm_compute_slice_shot(r0: int, r1: int, nx: int, ny: int, lc: PackedVector2Array) -> void:
	var fid := _bm_bake_fid
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var img: Image = _bm_bake_img
	for by in range(r0, r1):
		var t := (float(by) + 0.5) / float(ny)
		for bx in range(nx):
			var s := (float(bx) + 0.5) / float(nx)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var rec := SurfaceShot.surface_shot(fid, lx, lz, ctx)
			var idv := float(int(rec["block_id"])) / 255.0
			img.set_pixel(bx, by, Color(idv, float(rec["shade"]), 0.0, 1.0))

## FP_SKIN_FLATCOLOR worker-safe FLAT-COLOUR compute for rows [r0,r1): each column's exposed top block (SurfaceShot,
## incl. TreeGen) -> its FarPalette tile-mean colour INDEX (0..13)+1, stored L8 in R (0 = un-baked). `_edit_snap`
## (a main-thread snapshot of this facet's edits, empty until Stage B) overrides a column's top block so dig-outs /
## placed blocks show on the far map. A FRESH per-slice GenCtx homes every query on _bm_bake_fid (race-free worker).
func _bm_compute_slice_flat(r0: int, r1: int, nx: int, ny: int, lc: PackedVector2Array) -> void:
	# FAST flat-colour bake: terrain colours from the C++ sample_columns → far colour index; a CHEAP TreeGen overlay
	# (has_tree hash early-outs) + the edit snapshot pick the TOP block. Indices are written DIRECTLY into the L8 byte
	# buffer (no per-texel set_pixel); the staging Image is built once from the buffer on the last slice.
	var fid := _bm_bake_fid
	var tex := _bm_texels
	var have_edits: bool = not _edit_snap.is_empty()
	var rows := r1 - r0
	var packed := PackedInt64Array()
	var lxs := PackedInt32Array()
	var lzs := PackedInt32Array()
	packed.resize(rows * nx)
	lxs.resize(rows * nx)
	lzs.resize(rows * nx)
	for rj in range(rows):
		var by := r0 + rj
		var t := (float(by) + 0.5) / float(ny)
		var base := rj * nx
		for bx in range(nx):
			var s := (float(bx) + 0.5) / float(nx)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			lxs[base + bx] = lx
			lzs[base + bx] = lz
			packed[base + bx] = _pack_xz(lx, lz)
	var res: Dictionary = _sampler.call(fid, packed)   # C++ terrain colours (fast; no trees/edits)
	var cols: PackedColorArray = res["colors"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)          # facet-homed pcache for the tree overlay (worker-safe)
	for rj in range(rows):
		var by := r0 + rj
		var base := rj * nx
		var row_off := by * tex
		for bx in range(nx):
			var i := base + bx
			var bid := -1
			if have_edits:
				bid = int(_edit_snap.get(Vector2i(lxs[i], lzs[i]), -1))   # dig-out air / placed block wins
			if bid < 0:
				var deco := TreeGen.top_decoration(lxs[i], lzs[i], ctx)   # cheap: has_tree gate early-outs to AIR
				if deco != BlockCatalog.AIR:
					bid = deco
			var idx: int
			if bid >= 0:
				idx = FarPalette.far_color_index_of_block(bid) + 1   # tree/edit top block → tile-mean colour idx
			else:
				idx = FarPalette.far_color_index(cols[i]) + 1        # bare terrain colour → nearest palette idx
			_bm_bake_bytes[row_off + bx] = idx                    # direct L8 byte write (no set_pixel)
	if r1 >= ny:                                             # last slice → build the L8 image from the byte buffer once
		_bm_bake_img = Image.create_from_data(tex, tex, false, Image.FORMAT_L8, _bm_bake_bytes)

## MAIN commit: if the facet just completed, upload its ONE staging layer into the GPU array (the ONLY GPU touch),
## make it resident + record its (a,b)/(Nx,Ny) reverse-map, retain the active facet's staging image, bump the epoch
## and release the image. All residency-dict writes + update_layer are here (main only).
func _bm_commit_slice() -> void:
	if not _bm_last_done:
		return
	_bm_last_done = false
	var layer := _bm_bake_layer
	var fid := _bm_bake_fid
	var img: Image = _bm_bake_img
	var d := _decode(fid)
	_bm_tex.update_layer(img, layer)
	_bm_slots[fid] = layer
	_bm_facet[layer] = Vector2(float(d[1]), float(d[2]))
	_bm_n[layer] = Vector2(float(_bm_bake_nx), float(_bm_bake_ny))
	# Retain ONLY the active facet's L8 staging image on CPU (the design's single staging layer — for the Phase-3 edit
	# splats + a headless-readable id surface; get_layer_data can't read a GPU array headless). Non-active band facets
	# drop their image (re-bake from the generator on return) so band CPU stays at one layer.
	if fid == _bm_want_active:
		_bm_active_fid = fid
		_bm_active_img = img
	_bm_epoch += 1
	_bm_bake_fid = -1; _bm_bake_layer = -1; _bm_bake_img = null

## Evict band facet `fid`: free its layer, drop it from residency. The reverse-map (a,b)/(Nx,Ny) is left as-is until the
## layer is reused (a returning facet re-bakes it) so a mesh vertex carrying the stale 64+slot for the ≤1-frame window
## before the re-emit lands still samples a coherent layer (a soft no-op). The GPU layer keeps its stale id data until
## reused — harmless (no facet's UV2.y points at it once evicted). Bumps the epoch.
func _evict_band(fid: int) -> void:
	if not _bm_slots.has(fid):
		return
	var layer := int(_bm_slots[fid])
	_bm_slots.erase(fid)
	if not _bm_free.has(layer):
		_bm_free.append(layer)
	# Fable audit F1(ii): sentinel the freed layer's reverse-map row (-1,-1) so a far-ring mesh still carrying this
	# layer's UV2.y (evicted but not yet re-emitted) reads the shader's `_m.x < -0.5` fallback → the always-baked FINE
	# tier, NOT the stale (a,b) of a facet that may be reassigned to this layer next (which stretched a corner texel).
	if layer >= 0 and layer < _bm_facet.size():
		_bm_facet[layer] = Vector2(-1.0, -1.0)
	_bm_epoch += 1

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

## COSMOS TEXTURED-LOD T1b: the 6-layer L8 id map bound into the ring's `id_map` uniform (null until the first bake
## batch / off the flag). Gate + WorldManager surface.
func id_texture() -> Texture2DArray:
	return _id_tex

## The stored id (0 = un-baked, else FarPalette.detail_pattern + 1) at facet `fid`'s local texel (tx,ty). Off ⇒ -1.
## Gate surface for G-BD-ID / G-BD-OFF.
func id_at(fid: int, tx: int, ty: int) -> int:
	if not _bd_on:
		return -1
	var d := _decode(fid)
	var img: Image = _id_pages[int(d[0])]
	return int(round(img.get_pixel(int(d[1]) * BASE_TEXELS + tx, int(d[2]) * BASE_TEXELS + ty).r * 255.0))

func detail_on() -> bool:
	return _bd_on

func is_baked(fid: int) -> bool:
	return _baked.has(fid)

## COSMOS TEXTURED-LOD V4 (§2V.2, FP_SKIN_SSE): the RESOLVED skin fidelity tier currently resident for facet `fid` —
## the gate surface G-VD-MONO asserts is monotone non-decreasing across a descent. 3 = band (real per-block ids), 2 =
## close-up page, 1 = base map (baked), 0 = un-baked (vertex colour). A coarser value means the shader shows a lower-
## fidelity skin there; the descent-flat-color bug (Bug 1) is exactly this value REGRESSING (2→1) mid-descent.
func resolved_tier(fid: int) -> int:
	if _bm_slots.has(fid):
		return 3
	if _cu_slots.has(fid):
		return 2
	if _baked.has(fid):
		return 1
	return 0

func baked_count() -> int:
	return _baked.size()

# COSMOS TEXTURED-LOD V3 (FP_PAGES_SHOT) gate/telemetry surface.
func shot_on() -> bool:
	return _shot_on

func is_shot_baked(fid: int) -> bool:
	return _shot_baked.has(fid)

func shot_baked_count() -> int:
	return _shot_baked.size()

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

# --- U1 band accessors (gate + WorldManager surface) ---------------------------------------------

## The BAND_LAYERS-layer L8 band id map bound into the ring's `band_map` uniform (null off FP_BAND_BLOCK_MAP). Built
## whole (all id 0) at setup, so it is non-null whenever the band tier is live — its layers fill in as facets bake.
func band_texture() -> Texture2DArray:
	return _bm_tex

func band_on() -> bool:
	return _bm_on

## The RESIDENT band layer for `fid`, or −1 (tiled-detail fallback). WorldManager maps this to UV2.y as 64+layer at emit.
func band_slot(fid: int) -> int:
	return int(_bm_slots.get(fid, -1))

## A COPY of the resident band slot map (fid→layer) for WorldManager to push to the ring when the epoch bumps.
func band_slots() -> Dictionary:
	return _bm_slots.duplicate()

## The layer→(a,b) reverse map for the shader's `band_facet` uniform (facet-local UV = v_uv·K − (a,b)).
func band_facet_map() -> PackedVector2Array:
	return _bm_facet

## The layer→(Nx,Ny) block-count reverse map for the shader's `band_n` uniform (block frequency: id lookup + intra-block UV).
func band_n_map() -> PackedVector2Array:
	return _bm_n

## Bumped on any band resident-slot / reverse-map change → WorldManager pushes the new maps + requests a re-emit.
func band_epoch() -> int:
	return _bm_epoch

func band_resident_count() -> int:
	return _bm_slots.size()

func band_want_count() -> int:
	return _bm_want.size()

## Is facet `fid` currently in the band ring (active ∪ ring-1)? (gate G-BB-SLOT: evict-only-on-ring-exit invariant.)
func band_in_ring(fid: int) -> bool:
	return _bm_want.has(fid)

## The RESIDENT facet's per-axis block counts (Nx,Ny), or (0,0) if not resident. Gate surface for the shader-addressing check.
func band_n_of(fid: int) -> Vector2:
	if not _bm_slots.has(fid):
		return Vector2(0.0, 0.0)
	return _bm_n[int(_bm_slots[fid])]

## The stored band id (0 = un-baked, else FarPalette.detail_pattern+1) at the ACTIVE band facet's block (bx,by) ∈
## [0,Nx)×[0,Ny). Reads the retained active-facet CPU staging image (a GPU Texture2DArray layer is not readable headless);
## the active facet is the one the gate exercises, so this is the real stored id. −1 for a non-active / non-resident facet.
func band_id_at(fid: int, bx: int, by: int) -> int:
	if not _bm_on or fid != _bm_active_fid or _bm_active_img == null:
		return -1
	if bx < 0 or by < 0 or bx >= _bm_texels or by >= _bm_texels:
		return -1
	return int(round(_bm_active_img.get_pixel(bx, by).r * 255.0))

## COSMOS TEXTURED-LOD §2V V2: the stored SHOT shade byte (G channel of the RG8 band) ∈ [0,1] at the ACTIVE band facet's
## block (bx,by), or −1.0 off FP_BAND_SHOT / non-active / out of range. Gate surface for G-VS-SHOT (the shade round-trips).
func band_shade_at(fid: int, bx: int, by: int) -> float:
	if not _bm_shot or fid != _bm_active_fid or _bm_active_img == null:
		return -1.0
	if bx < 0 or by < 0 or bx >= _bm_texels or by >= _bm_texels:
		return -1.0
	return _bm_active_img.get_pixel(bx, by).g

## COSMOS TEXTURED-LOD §2V V2: is the band a REAL SHOT (RG8 {id,shade} incl trees) rather than the U1 L8 {id} map?
func band_shot_on() -> bool:
	return _bm_shot

## The band staging / GPU layer format: RG8 {id, shade} under FP_BAND_SHOT (the real shot, §2V), else L8 {id} (U1 band).
func _band_img_format() -> int:
	return Image.FORMAT_RG8 if _bm_shot else Image.FORMAT_L8

func worst_frame_ms() -> float:
	return float(_worst_frame_us) / 1000.0

func budget_spent_ms() -> float:
	return float(_budget_spent_us) / 1000.0

# --- TH1 (FP_TEX_BAKE_WORKER) offload wiring + gate surface --------------------------------------

## WorldManager wires the shared TH0 job lane in here after setup(). `_worker_on` is live ONLY when the flag is on AND
## the lane exists (FP_JOB_LANE) — so FP_TEX_BAKE_WORKER is inert without the lane (the design's requires-FP_JOB_LANE).
func set_job_lane(lane: JobLane) -> void:
	_lane = lane
	_worker_on = CubeSphere.FP_TEX_BAKE_WORKER and lane != null
	_setup_parallel_band()

## FP_SKIN_FLATCOLOR: arm the multi-core band bake (needs the worker + SSE residency). Slot count = cores − 1 (leave
## the main + render/gen threads headroom), capped at 8. Off ⇒ the shipped single-in-flight band path is used.
func _setup_parallel_band() -> void:
	_pbm_on = _bm_flat and _worker_on and CubeSphere.FP_SKIN_SSE
	if not _pbm_on:
		return
	# Reserve one core for the main/render thread: on a 2-core browser, running 2 bake workers alongside main
	# THRASHED (each fine facet took ~2.5s of contended CPU ⇒ throughput FELL to 0.8 facet/s vs ~5 with 1 clean
	# worker). The real speedups are the shade-skip (top_block_id) + the smaller fine texel + fine-priority, not more
	# workers. Scales up automatically when the web engine is rebuilt with a larger emscripten PTHREAD_POOL_SIZE and
	# the browser reports more logical cores.
	_pbm_n = clampi(OS.get_processor_count() - 1, 1, 8)
	_pbm_fid.resize(_pbm_n); _pbm_layer.resize(_pbm_n); _pbm_task.resize(_pbm_n)
	_pbm_bytes.resize(_pbm_n); _pbm_lc.resize(_pbm_n); _pbm_nx.resize(_pbm_n); _pbm_ny.resize(_pbm_n)
	_pbm_mode.resize(_pbm_n)
	for i in range(_pbm_n):
		_pbm_fid[i] = -1; _pbm_layer[i] = -1; _pbm_task[i] = -1; _pbm_mode[i] = 0
		_pbm_bytes[i] = PackedByteArray()
	_setup_fine_map()

func _setup_fine_map() -> void:
	_fm_on = CubeSphere.FP_PLANET_MAP and _pbm_on
	if not _fm_on:
		return
	_fm_texels = CubeSphere.PLANET_MAP_TEXELS
	_fm_quad = CubeSphere.PLANET_MAP_QUAD
	_fm_page = _fm_quad * _fm_texels
	FarPalette.ensure_far_index_ready()
	var imgs: Array[Image] = []
	for l in range(6 * 4):
		var im := Image.create(_fm_page, _fm_page, false, Image.FORMAT_L8)
		im.fill(Color(0.0, 0.0, 0.0, 1.0))   # id 0 = un-baked
		_fm_pages.append(im)
		imgs.append(im)
	_fm_tex = Texture2DArray.new()
	_fm_tex.create_from_images(imgs)

## Nearest un-baked whole-planet facet by emit axis (front-most first); covers all 6·K² facets, never evicted.
func _next_fine_fid(axis: Array) -> int:
	# Fable audit F4: once the whole planet is baked, both loops below scan all 6·K² (~7k) facets EVERY frame and
	# find nothing — a permanent idle-CPU tax after convergence. Early-out the moment coverage is complete.
	if _fine_baked.size() >= _base_all:
		return -1
	if axis.size() == 3:
		var ax := float(axis[0]); var ay := float(axis[1]); var az := float(axis[2])
		if ax * ax + ay * ay + az * az > 0.5:
			var best := -1
			var best_d := -2.0
			for fid in range(_base_all):
				if _fine_baked.has(fid) or _pbm_inflight(fid):
					continue
				var cd := _centre_pack[fid]
				var dt := cd.x * ax + cd.y * ay + cd.z * az
				if dt > best_d:
					best_d = dt; best = fid
			if best >= 0:
				return best
	for k in range(_base_all):
		var fid := (_fm_cursor + k) % _base_all
		if not _fine_baked.has(fid) and not _pbm_inflight(fid):
			_fm_cursor = (fid + 1) % _base_all
			return fid
	return -1

## Commit a finished fine tile (128²) into its sub-page: layer = face·4 + qy·2 + qx, offset = (a%12, b%12)·128.
func _fine_commit(fid: int, bytes: PackedByteArray) -> void:
	if bytes.size() != _fm_texels * _fm_texels:
		return
	var d := _decode(fid)
	var a := int(d[1]); var b := int(d[2])
	var qx := a / _fm_quad; var qy := b / _fm_quad
	var layer := int(d[0]) * 4 + qy * 2 + qx
	var tile := Image.create_from_data(_fm_texels, _fm_texels, false, Image.FORMAT_L8, bytes)
	_fm_pages[layer].blit_rect(tile, Rect2i(0, 0, _fm_texels, _fm_texels), Vector2i((a % _fm_quad) * _fm_texels, (b % _fm_quad) * _fm_texels))
	_fm_dirty[layer] = true
	_fine_baked[fid] = true

## The fine tier GPU array (bound by WorldManager as the shader's fine_map). Null off FP_PLANET_MAP.
func fine_texture() -> Texture2DArray:
	return _fm_tex
func fine_epoch() -> int:
	return _fm_epoch

func _pbm_inflight(fid: int) -> bool:
	for i in range(_pbm_n):
		if int(_pbm_fid[i]) == fid:
			return true
	return false

## Nearest wanted band facet not resident and not already in-flight (active first, then any).
func _next_band_parallel() -> int:
	if _bm_want.has(_bm_want_active) and not _bm_slots.has(_bm_want_active) and not _pbm_inflight(_bm_want_active):
		return _bm_want_active
	for fid in _bm_want.keys():
		var f := int(fid)
		if not _bm_slots.has(f) and not _pbm_inflight(f):
			return f
	return -1

## MAIN per-frame: reap finished parallel band slots (commit → resident) then dispatch idle slots. Called from update()
## when _pbm_on. The residency want (_bm_want) is refreshed by the SSE recompute on main before this.
func _update_band_parallel(emit_axis: Array = []) -> void:
	# 1) reap completed → commit on main (single-writer of the residency dicts)
	for i in range(_pbm_n):
		var fid := int(_pbm_fid[i])
		if fid < 0 or not WorkerThreadPool.is_task_completed(int(_pbm_task[i])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(_pbm_task[i]))   # reclaim + memory barrier
		var layer := int(_pbm_layer[i])
		_pbm_mutex.lock()
		var bytes: PackedByteArray = _pbm_bytes[i]
		_pbm_mutex.unlock()
		if int(_pbm_mode[i]) == 1:
			_fine_commit(fid, bytes)
			_pbm_fid[i] = -1; _pbm_task[i] = -1
			continue
		if bytes.size() == _bm_texels * _bm_texels:
			var img := Image.create_from_data(_bm_texels, _bm_texels, false, Image.FORMAT_L8, bytes)
			_bm_tex.update_layer(img, layer)
			_bm_slots[fid] = layer
			var d := _decode(fid)
			_bm_facet[layer] = Vector2(float(d[1]), float(d[2]))
			_bm_n[layer] = Vector2(float(int(_pbm_nx[i])), float(int(_pbm_ny[i])))
			_bm_epoch += 1
		else:
			_bm_free.append(layer)                                    # compute failed → return the layer
		_pbm_fid[i] = -1; _pbm_task[i] = -1
	# The whole-planet FINE tier is the COVERAGE guarantee; the band is close-up SUGAR. While any facet is still
	# un-fine-baked, the band yields ALL worker slots so the disc coverage fills fast (Fable F1 follow-up: the band's
	# expensive 174k-shot/facet bakes at mid-orbit were hogging both workers, starving the fine tier → the washed
	# mid-orbit disc). Once the planet is fully fine-covered, the band gets the slots to sharpen close approach. Uses
	# the size sentinel (no _next_fine_fid side-effect on _fm_cursor).
	var fine_pending: bool = _fm_on and _fine_baked.size() < _base_all
	# 2) dispatch idle slots to the next wanted band facets — ONLY when the fine coverage tier has nothing pending.
	if not fine_pending:
		for i in range(_pbm_n):
			if int(_pbm_fid[i]) >= 0:
				continue
			if _bm_free.is_empty():
				break
			var fid := _next_band_parallel()
			if fid < 0:
				break
			var layer := int(_bm_free.pop_back())
			var lc := PackedVector2Array()
			lc.resize(4)
			for ci in range(4):
				var w := FacetAtlas.facet_planar_corner(fid, ci)
				var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
				lc[ci] = Vector2(float(l[0]), float(l[2]))
			_pbm_fid[i] = fid
			_pbm_mode[i] = 0
			_pbm_layer[i] = layer
			_pbm_lc[i] = lc
			_pbm_nx[i] = clampi(int(round((lc[1] - lc[0]).length())), 1, _bm_texels)
			_pbm_ny[i] = clampi(int(round((lc[3] - lc[0]).length())), 1, _bm_texels)
			_pbm_task[i] = WorkerThreadPool.add_task(Callable(self, "_pbm_compute").bind(i), false, "flatband")
	# 3) FP_PLANET_MAP: dispatch the always-resident whole-planet fine bake into STILL-idle slots (band has priority)
	if _fm_on:
		for i in range(_pbm_n):
			if int(_pbm_fid[i]) >= 0:
				continue
			var ff := _next_fine_fid(emit_axis)
			if ff < 0:
				break
			var flc := PackedVector2Array()
			flc.resize(4)
			for ci in range(4):
				var w := FacetAtlas.facet_planar_corner(ff, ci)
				var l := FacetAtlas.world_to_lattice64(ff, w[0], w[1], w[2])
				flc[ci] = Vector2(float(l[0]), float(l[2]))
			_pbm_fid[i] = ff
			_pbm_mode[i] = 1
			_pbm_layer[i] = -1
			_pbm_lc[i] = flc
			_pbm_nx[i] = _fm_texels
			_pbm_ny[i] = _fm_texels
			_pbm_task[i] = WorkerThreadPool.add_task(Callable(self, "_pbm_compute").bind(i), false, "finemap")
		# throttled sub-page upload (one 2.36 MB update_layer every ~15 frames — measured-equivalent to band uploads)
		_fm_upload_cd -= 1
		if _fm_upload_cd <= 0 and not _fm_dirty.is_empty():
			var lyr := int(_fm_dirty.keys()[0])
			_fm_tex.update_layer(_fm_pages[lyr], lyr)
			_fm_dirty.erase(lyr)
			_fm_epoch += 1
			_fm_upload_cd = 15

## WORKER: compute slot `i`'s FULL facet L8 index bytes (pure per-slot state; the only shared write is _pbm_bytes[i]
## under the mutex). sample_columns (C++) is re-entrant by godot_voxel's threaded-generator design; TreeGen/FarPalette
## reads are static + read-only (LUTs built on main). No residency dict is touched here.
func _pbm_compute(i: int) -> void:
	# GDScript terrain sample (SurfaceShot: column_profile + FarPalette + TreeGen, per-call ctx) — read-only static
	# data, so it RUNS IN PARALLEL across worker threads (unlike the C++ sample_columns, which serialises on a lock).
	var fid := int(_pbm_fid[i])
	var tex := _fm_texels if int(_pbm_mode[i]) == 1 else _bm_texels
	var nx := int(_pbm_nx[i])
	var ny := int(_pbm_ny[i])
	var lc: PackedVector2Array = _pbm_lc[i]
	var have_edits: bool = not _edit_snap.is_empty()
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var bytes := PackedByteArray()
	bytes.resize(tex * tex)
	bytes.fill(0)
	for by in range(ny):
		var t := (float(by) + 0.5) / float(ny)
		var row_off := by * tex
		for bx in range(nx):
			var s := (float(bx) + 0.5) / float(nx)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			# The flat band + whole-planet fine tiers store a frozen-palette index (0..13; +1, 0 = un-baked). An EDIT
			# overlay cell is a real BLOCK id → its palette index via _block_idx; bare TERRAIN classifies its top
			# COLOUR directly (top_far_index). This split fixes the colour bug where the terrain path fed a detail-
			# PATTERN id into the block-id LUT (open water→mud, sand→stone). Shade-skipped ⇒ ~5-6× cheaper per column.
			var fi := -1
			if have_edits:
				var eb := int(_edit_snap.get(Vector2i(lx, lz), -1))
				if eb >= 0:
					fi = FarPalette.far_color_index_of_block(eb)
			if fi < 0:
				fi = SurfaceShot.top_far_index(lx, lz, ctx)
			bytes[row_off + bx] = fi + 1
	_pbm_mutex.lock()
	_pbm_bytes[i] = bytes
	_pbm_mutex.unlock()

## Gate-only hook: force the offload path with a supplied lane, independent of the FP_TEX_BAKE_WORKER const, so
## verify_tex_worker can drive BOTH paths in one flag state (the byte-identity comparison). Never called in production.
func _gate_force_worker(lane: JobLane) -> void:
	_lane = lane
	_worker_on = true

func worker_offload_on() -> bool:
	return _worker_on

## Gate-only hook (V3): force the g0/g1 shot generation on/off independent of FP_PAGES_SHOT, so verify_pages_shot can
## drive BOTH the palette (g0-only) and shot paths in one flag state (the byte-identity + convergence A/B). Pre-warms the
## statics surface_shot touches (matches setup) so a forced-on drive is worker-safe. Never called in production.
func _gate_set_shot(on: bool) -> void:
	_shot_on = on
	if on:
		FarPalette.ensure_ready()
		FarPalette.ensure_detail_ready()
		BlockCatalog.ensure_ready()

## Is a compute unit currently dispatched onto the lane worker? (gate: pump until this is false + lane idle.)
func job_inflight() -> bool:
	return _job_inflight

## The bake work paid ON MAIN in the last update() (ms) — the G-TW-MAINCOST proof: on-main path = the whole compute
## (large), worker path = orchestration + submit only (~0, the compute left the frame). Uploads are paid separately at
## the lane commit (JobLane.take_main_commit_ms), bounded to ≤ a few update_layer per frame.
func main_bake_ms() -> float:
	return float(_main_bake_us) / 1000.0

## Phase 2 telemetry (§6): the bake ledger streamed next to shell_telemetry() via the remote bridge. Bytes + coverage
## + close-up residency + the bounded-cost proof (worst per-update bake ms). {} when nothing has been baked yet.
func _pbm_busy_count() -> int:
	var c := 0
	for i in range(_pbm_n):
		if int(_pbm_fid[i]) >= 0:
			c += 1
	return c

func tex_telemetry() -> Dictionary:
	return {
		"tex_baked": _baked.size(),
		"tex_total": _base_all,
		"tex_spent_ms": snappedf(budget_spent_ms(), 0.01),
		"tex_worst_ms": snappedf(worst_frame_ms(), 0.01),
		"tex_bytes_kb": total_bytes() / 1024,
		"bm_on": _bm_on,
		"bm_flat": _bm_flat,
		"bm_res": _bm_slots.size(),
		"bm_want": _bm_want.size(),
		"bm_free": _bm_free.size(),
		"bm_bake": _bm_bake_fid,
		"bm_epoch": _bm_epoch,
		"pbm_n": _pbm_n,
		"pbm_busy": _pbm_busy_count(),

		"bm_facsz": band_facet_map().size(),
		"cu_on": _cu_on,
		"cu_resident": _cu_slots.size(),
		"cu_want": _cu_want.size(),
		"cu_free": _cu_free.size(),
		"cu_epoch": _slots_epoch,
		"shot_on": _shot_on,
		"shot_baked": _shot_baked.size(),
	}

## The TRUE NEVER-OOM footprint (§4): 6 CPU base pages + the base GPU array (+mips ≈ ×1.33) ≈ 8.2 MB; plus, under
## FP_FACET_TEX_CLOSEUP, CLOSEUP_MAX CPU staging layers + the close-up GPU array (+mips) ≈ 9.6 MB → ≈ 17.8 MB all-on.
## The gate asserts it stays under FACET_TEX_BYTES_MAX (20 MB). Every buffer is fixed-size at creation.
const FACET_TEX_BYTES_MAX := 512 * 1024 * 1024   # user raised the RAM budget (1GB-class host); band grown + headroom for the whole-planet tier
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
	# COSMOS TEXTURED-LOD T1b: the id pages (6 × _page² L8, no mips) — CPU staging + GPU array — plus the shared detail
	# atlas (built by FacetDetailAtlas, counted once here so the ledger is whole). Fixed-size ⇒ NEVER-OOM.
	if _bd_on:
		var id_px := _page * _page            # one L8 page, bytes
		total += 6 * id_px                     # 6 CPU staging id pages
		total += 6 * id_px                     # 6-layer GPU id array (L8, no mips)
		total += FacetDetailAtlas.total_bytes()
	# COSMOS TEXTURED-LOD U1 (§2U.4): the band id map — BAND_LAYERS × BAND_TEXELS² L8 GPU array (2.36 MB, no mips) + ONE
	# CPU staging image (the in-progress bake; row-sliced facets return re-bake from the generator, no per-facet CPU store).
	if _bm_on:
		var bpp := 2 if _bm_shot else 1                # §2V V2: RG8 {id,shade} shot = 2 B/block; U1 L8 {id} = 1 B/block
		var bm_px := _bm_texels * _bm_texels * bpp     # one band layer, bytes
		total += CubeSphere.band_layers() * bm_px        # BAND_LAYERS-layer GPU array (no mips)
		total += bm_px                                 # ONE CPU staging image (the active in-progress bake)
	# COSMOS FAR-RENDER-OVERHAUL §1.4 (Fable audit F2): the FP_PLANET_MAP whole-planet FINE tier — 24 L8 sub-page
	# layers of _fm_page² (=1536²), held BOTH as CPU staging Images (_fm_pages, the blit targets) AND the GPU array
	# (_fm_tex, no mips). ~56.6 MB each = ~113 MB. Must be on the ledger or the NEVER-OOM cap is a lie. Fixed-size.
	if _fm_on:
		var fine_layers := 6 * 4                          # 6 faces × 2×2 quadrants
		var fine_px := _fm_page * _fm_page                # one L8 sub-page layer, bytes
		total += fine_layers * fine_px                    # CPU staging Images (_fm_pages)
		total += fine_layers * fine_px                    # GPU array (_fm_tex, L8, no mips)
	return total

## COSMOS TEXTURED-LOD U1 (§2U.4): the band tier's own byte ledger (GPU array + one staging image), asserted ≤ BAND_BYTES_MAX
## by G-BB-BYTES. Zero off the flag. Kept separate so the gate can check the +2.7 MB delta arithmetic exactly.
func band_bytes() -> int:
	if not _bm_on:
		return 0
	var bpp := 2 if _bm_shot else 1                # §2V V2: RG8 shot = 2 B/block; U1 L8 = 1 B/block
	var bm_px := _bm_texels * _bm_texels * bpp
	return CubeSphere.band_layers() * bm_px + bm_px

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
