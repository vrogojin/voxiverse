// VOXIVERSE remote-bridge — shared PURE validators (no ws / no server deps), so the NEVER-OOM caps
// matrix is unit-testable without booting the relay. relay.mjs imports these; the GDScript rover mirrors
// them in remote_bridge.gd _validate_query_step (the rover never trusts the relay). Keep the three in sync.
//
// COSMOS-AGENT-CONTROL §5.2.

export const QUERY_HALF_MAX = 15;      // per-axis half-extent (dim ≤ 31)
export const QUERY_CELLS_MAX = 32768;  // Π(2h+1); 31³=29791 fits ⇒ ≤ 32 KiB u8 payload
export const QUERY_RAY_MAX = 64.0;     // raycast max distance (blocks)

// A finite [x,y,z] float vector (query origin/dir/center literal).
export function finiteVec3(v) {
  return Array.isArray(v) && v.length === 3 && v.every((n) => typeof n === 'number' && isFinite(n));
}

// Validate a query_box / query_ray step. Returns {ok:true, est} or {ok:false, detail}. The relay maps
// {ok:false} → rej('caps', detail) and {ok:true} → okEst(est).
export function validateQueryStep(st) {
  if (st.op === 'query_box') {
    if (st.center !== undefined && st.center !== 'player' && !finiteVec3(st.center))
      return { ok: false, detail: 'query_box.center must be "player" or [x,y,z]' };
    const h = st.half;
    if (!(Array.isArray(h) && h.length === 3 && h.every((n) => Number.isInteger(n) && n >= 0 && n <= QUERY_HALF_MAX)))
      return { ok: false, detail: `query_box.half must be 3 ints in [0,${QUERY_HALF_MAX}]` };
    const cells = (2 * h[0] + 1) * (2 * h[1] + 1) * (2 * h[2] + 1);
    if (cells > QUERY_CELLS_MAX) return { ok: false, detail: `query_box ${cells} cells > ${QUERY_CELLS_MAX}` };
    return { ok: true, est: 0.5 + cells / 32768 };        // time-sliced fill ⇒ ≤ ~1.5 s worst
  }
  if (st.op === 'query_ray') {
    if (st.origin !== undefined && st.origin !== 'eye' && !finiteVec3(st.origin))
      return { ok: false, detail: 'query_ray.origin must be "eye" or [x,y,z]' };
    if (st.dir !== undefined && st.dir !== 'look' && !(finiteVec3(st.dir) && Math.hypot(...st.dir) > 1e-6))
      return { ok: false, detail: 'query_ray.dir must be "look" or a non-zero [x,y,z]' };
    if (st.max_dist !== undefined && !(typeof st.max_dist === 'number' && st.max_dist > 0 && st.max_dist <= QUERY_RAY_MAX))
      return { ok: false, detail: `query_ray.max_dist must be in (0,${QUERY_RAY_MAX}]` };
    return { ok: true, est: 0.3 };
  }
  return { ok: false, detail: `not a query op '${st.op}'` };
}
