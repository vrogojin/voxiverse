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

## The radial sink (blocks) applied to backstop vertices at emit. Under the envelope the sink collapses to the
## small ε guard (the envelope already carries the lower-bound in the vertex height); otherwise it is DERIVED
## from facet geometry — BACKSTOP_SINK_FRAC × the facet cell size (cell = facet_edge/BACKSTOP_CELLS, facet_edge
## = (π/2·R)/K) — so it scales with R and never goes stale on a rescale (clears the coarse-grid chord error at
## any radius; ≈ 6 at R=3072, ≈ 13 at R=6371). This is the ONE site the sink value is decided.
static func backstop_sink() -> float:
	var cell := (PI * 0.5 * FacetAtlas.R_BLOCKS / float(FacetAtlas.K)) / float(CubeSphere.BACKSTOP_CELLS)
	if envelope_on():
		return maxf(ENV_EPS_G, ENV_EPS_FRAC * cell)   # ε guard scales with the cell (rescale-safe), floored at 1.5
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

static func make_biased_material(bias: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _TIER_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tier_bias", bias)
	return m
