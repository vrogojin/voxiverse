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

// ── COSMOS-AGENT-AUTONOMY — actuation op validators (shared relay ⇄ rover-mirrored) ─────────────────
export const NAV_RANGE_MAX = 64;       // Chebyshev blocks start→goal (rover also re-checks against live pos)

// A [x,y,z] array of finite INTEGERS — an absolute lattice cell.
export function vec3int(v) {
  return Array.isArray(v) && v.length === 3
    && v.every((n) => typeof n === 'number' && isFinite(n) && Number.isInteger(n));
}

// Validate a break_cell / place_cell / aim_cell / goto / chop_tree step. {ok:true, est} | {ok:false, detail}.
export function validateActStep(st) {
  switch (st.op) {
    case 'break_cell':
    case 'aim_cell':
      if (!vec3int(st.cell)) return { ok: false, detail: `${st.op}.cell must be an integer [x,y,z]` };
      return { ok: true, est: st.op === 'aim_cell' ? 1.0 : 0.5 };
    case 'place_cell':
      if (!vec3int(st.cell)) return { ok: false, detail: 'place_cell.cell must be an integer [x,y,z]' };
      if (st.block !== undefined && typeof st.block !== 'number' && typeof st.block !== 'string')
        return { ok: false, detail: 'place_cell.block must be a number or name' };
      return { ok: true, est: 0.5 };
    case 'goto': {
      if (!vec3int(st.cell)) return { ok: false, detail: 'goto.cell must be an integer [x,y,z]' };
      const g = st.goal ?? 'stand';
      if (g !== 'stand' && g !== 'adjacent') return { ok: false, detail: `bad goto.goal '${g}'` };
      return { ok: true, est: NAV_RANGE_MAX / 5.5 * 3 };   // ≈35 s conservative (range/walk×3)
    }
    case 'chop_tree': {
      const mr = st.max_range ?? 48;
      if (typeof mr !== 'number' || !Number.isInteger(mr) || mr < 8 || mr > NAV_RANGE_MAX)
        return { ok: false, detail: `chop_tree.max_range must be an int in [8,${NAV_RANGE_MAX}]` };
      return { ok: true, est: 60 };                        // bounded by SKILL_WATCHDOG_S
    }
  }
  return { ok: false, detail: `not an autonomy op '${st.op}'` };
}
