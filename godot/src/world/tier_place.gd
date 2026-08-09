class_name TierPlace
extends RefCounted
## COSMOS TIER-DEPTH-PRIORITY (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.0) — THE ONE swappable tier
## depth-priority policy site. The invariant it serves: wherever a finer tier covers the ground, every
## coarser tier must lose — near voxel blocks (authoritative) > skin heightfield > far-ring backstop >
## distant facets. Three independent mechanisms, each flag-gated, all reading their policy HERE:
##
##   P1 FP_TIER_STICKY_BACKSTOP — make-before-break roles (RC-B, the transient 15-25-block FLASH).
##   P2 FP_TIER_ENVELOPE        — the min-envelope vertex rule (RC-A, the steady ~4-block corner poke).
##   P3 FP_TIER_DEPTH_BIAS      — per-tier window-space depth bias + raised near plane (RC-C, latent precision).
##
## Pure statics, no state, no engine deps beyond CubeSphere/FacetAtlas. With every FP_TIER_* flag OFF every
## accessor returns the shipped value, so the engine is byte-identical (FLAT 6035/0). This class is DEAD
## (never referenced on a hot path) unless a tier flag is on.

# --- P2 envelope (§5.1) ------------------------------------------------------------------------------
const ENV_EPS_G := 1.5            # residual g guard FLOOR (blocks) once the min-envelope replaces the constant sink:
                                  # absorbs the between-fine-sample residual (detail-noise/shelf-knee) + f32 rounding.
const ENV_EPS_FRAC := 0.2         # the guard SCALES with the facet cell like BACKSTOP_SINK_FRAC: the between-fine-sample
                                  # chord sag grows with the cell (∝ R), so a fixed 1.5 goes stale on a rescale. guard =
                                  # max(ENV_EPS_G, ENV_EPS_FRAC × cell): ≈1.5 floor at R=3072, ≈5.2 at R=6371 (clears the
                                  # R=6371 poke with margin). Single derivation site (backstop_sink), rescale-safe by construction.
const ENV_FINE_MULT := 4          # fine-sample density = ENV_FINE_MULT × BACKSTOP_CELLS per facet edge — the
                                  # resolution the per-footprint minimum is taken at (pitch ≈ edge/(4·16) ≈ 3.1 blocks).
const ENV_DILATE_BLOCKS := 6.0    # footprint dilation (blocks) for the radial-vs-normal skew reach (relief·sin α_max
                                  # ≤ ~5-6 at K=24): the far vertex lands displaced ≤ this from its footprint b.

# --- COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D (§7.1, FP_RIM_CHEAP) — the S2 collar's OWN, cheaper
# fine-grid multiplier + its no-protrusion compensation. The shipped `_env_weld_grid` always samples at
# ENV_FINE_MULT(4) × cells — for S2 (cells=104) that is 417² ≈ 174k `profile_at_dir` calls/facet, the confirmed
# warmup allocator-convoy source (R5.3: per-texel GDScript allocation convoys the WASM allocator with the main
# thread — the SAME mechanism `voxiverse-walk-perf-root-cause` names). RIM_FINE_MULT=2 cuts that to ~43k (~4×);
# the web build goes one step further to RIM_FINE_MULT_WEB=1 (~11k, ~16×) since a 2-core browser main thread is
# the most convoy-sensitive. -----------------------------------------------------------------------------------
const RIM_FINE_MULT := 2          # S2-ONLY fine-sample density override (desktop/native): coarser than the
                                  # shipped ENV_FINE_MULT(4), used ONLY by `FacetSmoothTier.build_tile_rim`'s
                                  # `_env_weld_grid` call under FP_RIM_CHEAP — every other envelope caller
                                  # (coarse horizon / dense backstop) is untouched.
const RIM_FINE_MULT_WEB := 1      # web build: the coarsest still-covered mult (see RIM_ENV_RESID below) — web is
                                  # the 2-core convoy-sensitive target the whole flag exists for.
## RIM_ENV_RESID: the no-protrusion compensation. A coarser fine grid can only MISS a low column (fewer candidate
## samples ⇒ the per-node minimum can only stay the same or go UP vs the ENV_FINE_MULT(4) reference — never down),
## so `build_tile_rim` subtracts this from the coarsened envelope before it ever reaches the blend, restoring
## env_coarse − RIM_ENV_RESID ≤ env_fine ≤ true (no-protrusion preserved by construction, not a tuned visual fudge).
## MEASURED (2026-08-04, throwaway harness driving `FacetFarRing._env_weld_grid(fid, 104, mult)` at the real S2
## cells=104 against 58 facets spanning all 6 faces incl. the mountain biome — MOUNTAIN_AMPLITUDE=92 but its mask
## is low-frequency (wavelength ≈1250 blocks ≈3 facet-edges) so it is locally near-flat at S2's ~4-block scale;
## the sampled residual is dominated by HILLS(freq 0.008, amp 3)/DETAIL(freq 0.05, amp 1) noise instead): node-wise
## max(env@mult2 − env@mult4) and max(env@mult1 − env@mult4) both converged to ≈1.0006 blocks (consistent to 4
## decimal places across every facet sampled — bounded by the int `g` quantization, not by terrain roughness) — a
## SINGLE constant safely covers both RIM_FINE_MULT and RIM_FINE_MULT_WEB. +≈2 blocks of margin (facets the sparse
## scan didn't hit) ⇒ 3.0. G-RIM-MULT re-derives this bound live (falsified by forcing RIM_ENV_RESID=0).
const RIM_ENV_RESID := 3.0

# --- NO-PROTRUSION (FP_ENV_ALL, §0.3/§0.4) — the GLOBAL envelope ε, sized to the MEASURED inherent residual --------
const ENV_ALL_EPS_FRAC := 0.45    # the FP_ENV_ALL ε guard SCALES with the facet cell like ENV_EPS_FRAC, but larger:
                                  # even after the min-envelope removes the terrain-curvature over-estimate, a residual
                                  # ≈ the sagitta / radial-vs-normal datum offset (~6.2 blocks at R=6371, the SAME
                                  # residual the shipped FP_TIER_ENVELOPE backstop leaves — verify_tier_depth's +1.05
                                  # poke) remains that NO footprint widening removes. G-NPT-BOUND measures it and this
                                  # guard (ε = max(ENV_EPS_G, 0.45·cell) ≈ 11.7 at R=6371) provably covers it so the
                                  # rendered surface is ≤ true with ZERO protrusion. env_all-SCOPED: FP_TIER_ENVELOPE
                                  # keeps its own 0.2 guard ⇒ verify_tier_depth is byte-unmoved.

# --- P3 depth bias (§5.2 / §3.3) --------------------------------------------------------------------
const DEPTH_QUANTUM := 5.9604644775390625e-08   # 2⁻²⁴ — one window-depth quantum of the WebGL2 24-bit buffer.
const FAR_BIAS_K := 8             # far ring (backstop + distant): pushed 8 quanta behind at every distance.
const SKIN_BIAS_K := 4            # skin: 4 quanta behind (still ahead of the far ring, behind the near blocks).
const CAMERA_NEAR := 0.25         # raised faceted camera near plane (0.05 → 0.25 = 5× depth precision).

# --- P1 sticky (§5.3) -------------------------------------------------------------------------------
const RING1_MAX := CubeSphere.STICKY_RING1_MAX   # the sticky-set hard cap (re-exported for the gate).

# ====================================================================================================
# Policy accessors — each returns the SHIPPED value when its flag is off (byte-identical guarantee).
# ====================================================================================================

## P1: is the sticky/make-before-break backstop role active? (Requires the full-coverage far ring.)
static func sticky_on() -> bool:
	return CubeSphere.FP_TIER_STICKY_BACKSTOP and CubeSphere.FP_FARRING_FULL_COVER

## P2: is the min-envelope vertex rule active? (Requires the full-coverage far ring.)
static func envelope_on() -> bool:
	return CubeSphere.FP_TIER_ENVELOPE and CubeSphere.FP_FARRING_FULL_COVER

## P3: is the per-tier depth bias / raised near plane active?
static func depth_bias_on() -> bool:
	return CubeSphere.FP_TIER_DEPTH_BIAS

## NO-PROTRUSION (§0.3): is the GLOBAL ENVELOPE HEIGHT LAW active? Requires the full-coverage far ring (the thing
## whose caches carry the vertex heights) AND FP_SHELL_WELD (env_all only implements the radial-weld builders — the
## shipped planar path is never enveloped, so a weld-off run stays byte-identical). When on, EVERY far-ring vertex
## (coarse horizon + dense backstop) is a min-envelope lower bound and the ε sink applies to the coarse path too.
static func env_all_on() -> bool:
	return CubeSphere.FP_ENV_ALL and CubeSphere.FP_FARRING_FULL_COVER and CubeSphere.FP_SHELL_WELD

## P1-adjacent: is the surface warm-gate convergence (progressive cached-subset emit) active? Requires the full-coverage
## far ring (the backstop dense caches are the thing whose slow warm strands the all-or-nothing gate). Off ⇒ the shipped
## all-or-nothing surface warm gate runs verbatim (byte-identical).
static func warm_converge_on() -> bool:
	return CubeSphere.FP_TIER_WARM_CONVERGE and CubeSphere.FP_FARRING_FULL_COVER

## The radial sink (blocks) applied to backstop vertices at emit. Under the envelope the sink collapses to the
## small ε guard (the envelope already carries the lower-bound in the vertex height); otherwise it is DERIVED
## from facet geometry — BACKSTOP_SINK_FRAC × the facet cell size (cell = facet_edge/BACKSTOP_CELLS, facet_edge
## = (π/2·R)/K) — so it scales with R and never goes stale on a rescale (clears the coarse-grid chord error at
## any radius; ≈ 6 at R=3072, ≈ 13 at R=6371). This is the ONE site the sink value is decided.
static func backstop_sink() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	if env_all_on():
		return maxf(ENV_EPS_G, ENV_ALL_EPS_FRAC * cell)   # NO-PROTRUSION: the larger global-envelope guard (covers the
		                                                  # inherent radial/datum residual; env_all-scoped ⇒ tier gate unmoved)
	if envelope_on():
		return maxf(ENV_EPS_G, ENV_EPS_FRAC * cell)   # ε guard scales with the cell (rescale-safe), floored at 1.5
	return CubeSphere.BACKSTOP_SINK_FRAC * cell

## COSMOS TEXTURED-LOD U3 (§2U.3 — same level, cull-not-sink): is the far-ring SAME-LEVEL rule active at the FLAG
## level? Requires U2's FP_FARRING_CULL_COVERED — the ~13-block visual sink can only be removed where the cull
## guarantees near/far never coexist. Off ⇒ backstop_sink() keeps the full sink (byte-identical). NOTE: the far ring
## additionally requires a VALID coverage probe at RUNTIME before it applies the reduction (FacetFarRing._level_on
## gates on _cull_on), so on the GDScript fallback path (invalid probe) it self-disables to today's sink.
static func level_on() -> bool:
	return CubeSphere.FP_FARRING_LEVEL and CubeSphere.FP_FARRING_CULL_COVERED

## COSMOS-NEAR-FAR-HEIGHT-DESIGN.md §3 (FP_FARRING_APPLIED_COVER): is the near↔far height-step fix active at the
## FLAG level? REFINES FP_FARRING_UNCOVERED_TRUE (never fires without it — the applied-cover law only splits
## territory that law's zone-A/covered test already governs). Off ⇒ byte-identical (the deployed two-zone blend
## runs verbatim).
static func applied_cover_on() -> bool:
	return CubeSphere.FP_FARRING_APPLIED_COVER and CubeSphere.FP_FARRING_UNCOVERED_TRUE

## COSMOS TEXTURED-LOD U3: the far ring's radial sink COLLAPSED to the ENV_EPS_G correctness guard only — the backstop
## sits at essentially the near surface radius (a tiny ε below, never the ~13-block visual displacement). Same ε guard
## the min-envelope uses (max(ENV_EPS_G, ENV_EPS_FRAC×cell); ≈1.5 floor at R=3072, ≈5.2 at R=6371) — it covers the
## between-fine-sample residual so far ≤ near (no protrusion). Rescale-safe (scales with the facet cell like
## backstop_sink). The far ring routes here (via _sunk_positions) ONLY when _level_on(); fringe z-order at the
## un-culled seam is the shipped FAR_BIAS_K window-space depth bias, not this sink.
static func backstop_sink_level() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	return maxf(ENV_EPS_G, ENV_EPS_FRAC * cell)

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-D: the INTERIM floor sink for a rim-eligible (active ∪
## live-pool) facet that has not yet had its first FP_SMOOTH_RIM S2 tile commit. The plain `backstop_sink()` dip
## (BACKSTOP_SINK_FRAC-scaled, ≈13 blocks at R=6371) is what R.1.d root-caused as the visible "FAR renders below
## NEAR" during streaming; this collapses it to the same small ε-guard the min-envelope law already proves safe
## (max(ENV_EPS_G, ENV_EPS_FRAC·cell) ≈ 1.5-5.2 blocks — sub-cell, not the full sink). Scoped by the CALLER to
## FP_SMOOTH_RIM ∧ rim-eligible ∧ pre-first-S2-commit only (byte-identical off / once S2 has committed, since the
## facet is then drawn by the S2 tile, not this plain backstop plane, via the shared law-6 emit-exclusion).
static func backstop_sink_rim() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	return maxf(ENV_EPS_G, ENV_EPS_FRAC * cell)

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D (FP_RIM_CHEAP, §7.1 (i)): the S2 collar's fine-sample
## multiplier — RIM_FINE_MULT_WEB on a web export (OS.has_feature("web"), the convoy-sensitive target), else
## RIM_FINE_MULT. Off (FP_RIM_CHEAP false) ⇒ callers pass -1 to `_env_weld_grid` (the shipped ENV_FINE_MULT),
## never calling this at all — byte-identical.
static func rim_fine_mult() -> int:
	return RIM_FINE_MULT_WEB if OS.has_feature("web") else RIM_FINE_MULT

## The no-protrusion compensation paired with `rim_fine_mult()` — see RIM_ENV_RESID's derivation above. One
## constant covers both the desktop and web mult (measured equal to 4 decimal places on the sampled fixture set).
static func rim_env_resid() -> float:
	return RIM_ENV_RESID

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D (FP_RIM_CHEAP, §7.1 (ii) crescent rebake): the padding
## `build_tile_rim`'s crescent annulus test adds (beyond feather+drift) to cover the gap between a node's CHEAP
## planar proxy position (`FarDensity.node_dir(...) * r_datum`, no noise sample — used to decide "safe to reuse
## without a fresh node_at call") and its TRUE relieved position. Reuses the SAME bound `ENV_ALL_EPS_FRAC` already
## derives for the conceptually IDENTICAL question elsewhere in this file ("how far can the min-envelope's own
## dilated-footprint construction differ from the true surface" — `backstop_sink()`'s env_all branch, G-NPT-BOUND
## measured) rather than the theoretical GLOBAL max relief (`TerrainConfig.MAX_SURFACE_Y`, ~116 blocks at R=6371):
## the global bound is RIGOROUS but would swamp the annulus test almost everywhere near a modest S2 disc (r_env ≈
## 160), defeating the crescent's purpose; this measured, already-gate-proven bound (≈11.7 at R=6371) is the
## established precedent for exactly this class of claim in this codebase. A node whose planar-proxy distance to
## BOTH the old and new column stays outside `[r_env−feather−drift−pad, r_env+feather+drift+pad]` is therefore
## reuse-eligible — see `build_tile_rim`'s doc comment for the full argument.
static func rim_crescent_pad() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	return maxf(ENV_EPS_G, ENV_ALL_EPS_FRAC * cell)

## FP_ENV_FLOORED_ASYNC: the FULL radial sink for a CHORD fallback vertex — the exact pre-envelope BACKSTOP_SINK
## (BACKSTOP_SINK_FRAC × cell, ≈13 at R=6371), regardless of env_all. A chord is the raw profile sample, NOT the
## min-envelope, so it needs the full sink (not the ε) to sit ≤ the near surface — byte-for-byte the FULL_COVER
## backstop that shipped live before FP_ENV_ALL. Used by _emit_cached for a not-yet-enveloped dense/coarse facet.
static func backstop_sink_chord() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	return CubeSphere.BACKSTOP_SINK_FRAC * cell

## P3: the window-space depth-bias uniform value for tier `k` quanta = 2·k·2⁻²⁴ (POSITION.z += bias·w).
static func bias_for_k(k: int) -> float:
	return 2.0 * float(k) * DEPTH_QUANTUM

static func far_bias() -> float:
	return bias_for_k(FAR_BIAS_K)

static func skin_bias() -> float:
	return bias_for_k(SKIN_BIAS_K)

# ====================================================================================================
# P1 — the sticky backstop target set (active ∪ ring-1 neighbours). "Make before break": these facets
# are drawn sunk BEFORE they enter the pool, so a crossing never pairs a live near mesh with an unsunk
# coarse quad. Ring-1 = the active facet's 4 seam neighbours plus THEIR seam neighbours (the diagonals),
# deduped, capped at RING1_MAX. Excludes -1 (no neighbour across a twist/edge).
# ====================================================================================================
static func ring1(active_fid: int) -> PackedInt32Array:
	var out := PackedInt32Array([active_fid])
	var direct := PackedInt32Array()
	for slot in range(4):
		var n := FacetAtlas.seam_neighbour(active_fid, slot)
		if n >= 0 and not out.has(n):
			out.append(n)
			direct.append(n)
	# One more ring of seam neighbours off the direct neighbours → the diagonal ring-1 facets.
	for nf in direct:
		for slot in range(4):
			var d := FacetAtlas.seam_neighbour(nf, slot)
			if d >= 0 and d != active_fid and not out.has(d):
				out.append(d)
				if out.size() >= RING1_MAX:
					return out
	return out

# ====================================================================================================
# P3 — the biased tier material. A LIT, vertex-colour spatial ShaderMaterial equivalent to the far-ring /
# skin StandardMaterial3D (roughness 1, cull disabled, fog + tonemap applied by the environment), PLUS a
# constant window-space depth offset so the tier loses every depth tie in order. Built only under the flag;
# the near atlas material is NEVER routed here (the authoritative tier stays unbiased on its tested path).
# ====================================================================================================
const _TIER_SHADER := "shader_type spatial;
render_mode cull_disabled;
uniform float tier_bias;
varying vec3 v_col;
void vertex() {
	v_col = COLOR.rgb;
	POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	POSITION.z += tier_bias * POSITION.w;
}
void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 1.0;
}
"

# COSMOS TEXTURED-LOD V1 (FP_SHADE_UNIFIED, docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.3): the biased-tier fallback far
# material, self-shaded by the SHARED VoxiLight law so — where this material carries the far ring instead of the shell
# absolute shader — it shades IDENTICALLY to the near blocks. UNSHADED (like the shell) + the TRUE planet-radial normal
# n = normalize(wp − MODEL·0), × voxi_shade, keeping the P3 window-space depth bias. VoxiLight.SHADE_GLSL is string-
# included (pure concatenation — ONE shader_type, zero new compiled program). Off ⇒ make_biased_material uses _TIER_
# SHADER verbatim (byte-identical). sun_dir is fed each frame via FacetFarRing.set_shell_absolute_sun_dir (relaxed guard).
const _TIER_UNIFIED_HEAD := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float tier_bias;
"
const _TIER_UNIFIED_TAIL := "varying vec3 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	v_col = COLOR.rgb * voxi_shade(n, sun_dir);
	POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	POSITION.z += tier_bias * POSITION.w;
}
void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 1.0;
}
"

## The biased-tier shader source. `unified` off (default = the flag) ⇒ the shipped _TIER_SHADER VERBATIM; on ⇒ the same
## depth-biased material self-shaded by the shared VoxiLight law. Exposed static so the G-VL-EQ gate can build both.
static func tier_shader_code(unified := CubeSphere.FP_SHADE_UNIFIED) -> String:
	if unified:
		return _TIER_UNIFIED_HEAD + VoxiLight.shade_glsl() + _TIER_UNIFIED_TAIL
	return _TIER_SHADER

## FP_FAR_TERMINATOR_WELD: the last live Sun direction ANY caller pushed via `note_sun_dir` (shared by every
## consumer of `make_biased_material` — the far-ring shell AND `FacetSkinTier`). Read by `make_biased_material`
## to seed a NEW instance with the live Sun instead of the hardcoded (1,0,0) fake-noon default. This is the
## "TierPlace biased" gap from docs/COSMOS-FAR-TERMINATOR-DESIGN.md §1: `FacetSkinTier`'s biased material is
## built ONCE at setup and had NO refresh path at all before this flag. Off ⇒ never written/read ⇒ byte-identical.
static var _last_sun_dir := Vector3(1.0, 0.0, 0.0)

## FP_FAR_TERMINATOR_WELD: record a live Sun push so the NEXT `make_biased_material` call seeds from it. Callers:
## `FacetFarRing.set_shell_absolute_sun_dir` and `FacetSkinTier.set_sun_dir`. Off ⇒ no-op (byte-identical).
static func note_sun_dir(sun_dir: Vector3) -> void:
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_last_sun_dir = sun_dir

static func make_biased_material(bias: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = tier_shader_code()
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tier_bias", bias)
	# Unified: seed the ONE uniform set so the tier material shades identically to near/far (sun_dir fed each frame).
	if CubeSphere.FP_SHADE_UNIFIED:
		# FP_FAR_TERMINATOR_WELD: seed from the last live Sun any biased-material consumer was told about, not the
		# hardcoded default — kills FacetSkinTier's build-once-never-refreshed fake-noon freeze. Off ⇒ the shipped
		# hardcoded seed verbatim (byte-identical; _last_sun_dir stays at its own (1,0,0) default when unwritten).
		var seed := _last_sun_dir if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
		m.set_shader_parameter("sun_dir", seed)
		m.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		m.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		m.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return m
