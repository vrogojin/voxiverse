// COOP/COEP header source-of-truth for the web-soak static server.
//
// These MUST stay byte-identical to the production nginx config
// (docker/server/voxiverse.conf.template, server-scope add_header lines ~37-40)
// and to what scripts/deploy.sh verifies live (deploy.sh:141-142). The threaded
// WASM export needs SharedArrayBuffer -> cross-origin isolation -> BOTH of
// COOP:same-origin + COEP:require-corp on EVERY response, or `crossOriginIsolated`
// is false and the Godot engine refuses to boot (blank page). This is the #1
// web-serving gotcha; the soak server exists to reproduce it faithfully offline.
//
// If the nginx template changes, change this table in the same PR.
export const COOP_COEP_HEADERS = Object.freeze({
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'X-Content-Type-Options': 'nosniff',
});

// The two headers scripts/deploy.sh treats as the hard live gate.
export const REQUIRED_ISOLATION_HEADERS = Object.freeze([
  ['cross-origin-opener-policy', 'same-origin'],
  ['cross-origin-embedder-policy', 'require-corp'],
]);
