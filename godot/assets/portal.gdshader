shader_type spatial;
// See-through portal surface (PORTALS §3.5.4). The SubViewport pass already applied
// ambient + depth fog under the same WorldEnvironment, so the quad must NOT re-shade or
// re-fog the image: unshaded + fog_disabled. cull_disabled → both faces show the live
// view. ONE shader → one GL-Compatibility pipeline → one ShaderPrewarm job; per-portal
// state (the view texture, the per-side U flip) lives on a per-portal ShaderMaterial
// instance (Compatibility has no instance uniforms).
render_mode unshaded, fog_disabled, cull_disabled;

uniform sampler2D view_tex : source_color, filter_linear;
// Per-side horizontal flip: set from PortalMath (true when the player is on the source
// frame's BACK, §3.5.3). Recomputed only when the player crosses the source plane.
uniform bool flip_u = false;
// One empirical vertical flip for the SubViewport render-target orientation — a single
// global constant across all portals, pinned by the live landmark eyeball test (§3.5.3).
// The window-frustum camera renders a Y-UPRIGHT image (camera up is always +Y; the NDC
// verify shows a frame's bottom corners map to NDC bottom, not inverted) and the GL-
// Compatibility / WebGL2 viewport texture sampled by UV is NOT vertically inverted, so
// NO extra flip is needed — flip_v = true left the live view upside-down (and, from an
// eye not level with the opening, the inverted ground plane read as an incline). Corrected
// to false after the live /portals/ report. A uniform (not a #define) so it needs no new
// pipeline. If a build's render target ever samples inverted, flip this back to true.
uniform bool flip_v = false;

void fragment() {
	vec2 uv = UV;
	if (flip_u) { uv.x = 1.0 - uv.x; }
	if (flip_v) { uv.y = 1.0 - uv.y; }
	ALBEDO = texture(view_tex, uv).rgb;
}
