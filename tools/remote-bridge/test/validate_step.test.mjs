// COSMOS-AGENT-CONTROL §5.6 — relay gate for the FP_AGENT_QUERY NEVER-OOM caps (query_box/query_ray).
// Pure unit test of the shared validator (validate.mjs) that relay.mjs delegates to AND the GDScript rover
// (_validate_query_step) mirrors — so one caps matrix covers both wire-side checks. No ws / no server boot.
//
// Run: node tools/remote-bridge/test/validate_step.test.mjs
//
// (The fs.watch pickup latency — write→forward — is a relay-RUNTIME property measured in the live A/B,
//  since the relay needs its ws dependency; this gate pins the caps logic that guards never-OOM.)

import { validateQueryStep, QUERY_HALF_MAX, QUERY_CELLS_MAX, QUERY_RAY_MAX } from '../validate.mjs';

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) { pass++; } else { fail++; console.log('  FAIL:', msg); } }
function accepts(st, msg) { ok(validateQueryStep(st).ok === true, msg); }
function rejects(st, msg) { ok(validateQueryStep(st).ok === false, msg); }

// ── query_box: valid ─────────────────────────────────────────────────────────────────────────
accepts({ op: 'query_box', center: 'player', half: [4, 3, 4] }, 'box: player-centered 9×7×9');
accepts({ op: 'query_box', half: [0, 0, 0] }, 'box: single cell (half 0)');
accepts({ op: 'query_box', half: [15, 15, 15] }, `box: max half ${QUERY_HALF_MAX} (31³=29791 ≤ ${QUERY_CELLS_MAX})`);
accepts({ op: 'query_box', center: [10, 20, 30], half: [2, 2, 2] }, 'box: explicit [x,y,z] center');

// ── query_box: invalid (caps + shape) ───────────────────────────────────────────────────────
rejects({ op: 'query_box', half: [16, 0, 0] }, `box: half > ${QUERY_HALF_MAX} rejected`);
rejects({ op: 'query_box', half: [-1, 0, 0] }, 'box: negative half rejected');
rejects({ op: 'query_box', half: [4, 4] }, 'box: half not length-3 rejected');
rejects({ op: 'query_box', half: [2.5, 2, 2] }, 'box: non-integer half rejected');
rejects({ op: 'query_box' }, 'box: missing half rejected');
rejects({ op: 'query_box', center: 'origin', half: [1, 1, 1] }, 'box: bad center literal rejected');
rejects({ op: 'query_box', center: [1, 2], half: [1, 1, 1] }, 'box: 2-vec center rejected');
rejects({ op: 'query_box', center: [1, 'x', 3], half: [1, 1, 1] }, 'box: non-number center rejected');

// The cell-count cap is the never-OOM ceiling; every valid half stays within it by construction.
ok((2 * QUERY_HALF_MAX + 1) ** 3 <= QUERY_CELLS_MAX, `sanity: max box (31³) ≤ QUERY_CELLS_MAX (${QUERY_CELLS_MAX})`);

// ── query_ray: valid ─────────────────────────────────────────────────────────────────────────
accepts({ op: 'query_ray' }, 'ray: eye/look defaults');
accepts({ op: 'query_ray', origin: 'eye', dir: 'look', max_dist: 8 }, 'ray: explicit defaults + max_dist');
accepts({ op: 'query_ray', origin: [1, 2, 3], dir: [0, 0, 1] }, 'ray: explicit origin+dir');
accepts({ op: 'query_ray', max_dist: QUERY_RAY_MAX }, `ray: max_dist == ${QUERY_RAY_MAX}`);

// ── query_ray: invalid ─────────────────────────────────────────────────────────────────────
rejects({ op: 'query_ray', max_dist: 65 }, `ray: max_dist > ${QUERY_RAY_MAX} rejected`);
rejects({ op: 'query_ray', max_dist: 0 }, 'ray: max_dist 0 rejected');
rejects({ op: 'query_ray', max_dist: -5 }, 'ray: negative max_dist rejected');
rejects({ op: 'query_ray', dir: [0, 0, 0] }, 'ray: zero dir rejected');
rejects({ op: 'query_ray', dir: [1, 2] }, 'ray: 2-vec dir rejected');
rejects({ op: 'query_ray', origin: 'nose' }, 'ray: bad origin literal rejected');
rejects({ op: 'query_ray', origin: [1, Infinity, 3] }, 'ray: non-finite origin rejected');

// ── non-query op is not accepted by the query validator (defense-in-depth) ────────────────────
rejects({ op: 'move', blocks: 4 }, 'non-query op not accepted by query validator');
rejects({ op: 'query_sphere' }, 'unknown query-ish op rejected');

console.log(`==== VALIDATE-STEP: ${pass} passed, ${fail} failed ====`);
process.exit(fail > 0 ? 1 : 0);
