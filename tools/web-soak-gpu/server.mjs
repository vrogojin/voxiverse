// Minimal cross-origin-isolated static server for the Godot web export.
//
// Serves build/web/ with the production COOP/COEP headers on EVERY response
// (including 404s and the .wasm/.pck engine assets), mirroring
// docker/server/voxiverse.conf.template. This is the ONLY thing the harness needs
// from the deploy stack: a header-faithful origin. No TLS, no HAProxy, no caching
// policy — just correctness of the isolation headers so `crossOriginIsolated` is
// true and the threaded engine boots.
//
// Usage:
//   node server.mjs [--root <dir>] [--port <n>]
// Defaults: root = ../../build/web relative to this file, port = 0 (ephemeral).
// On listen it prints one line: "web-soak-server listening http://127.0.0.1:<port> root=<abs>"

import http from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { COOP_COEP_HEADERS } from './lib/coop-headers.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.wav': 'audio/wav',
};

function applyIsolationHeaders(res) {
  for (const [k, v] of Object.entries(COOP_COEP_HEADERS)) res.setHeader(k, v);
}

export function createServer(root) {
  const rootAbs = path.resolve(root);
  return http.createServer(async (req, res) => {
    // COOP/COEP on EVERY response — before any branch, so even errors carry them.
    applyIsolationHeaders(res);
    try {
      let urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
      if (urlPath === '/' || urlPath === '') urlPath = '/index.html';
      // Resolve inside root; reject traversal.
      const filePath = path.join(rootAbs, path.normalize(urlPath));
      if (!filePath.startsWith(rootAbs)) {
        res.writeHead(403).end('forbidden');
        return;
      }
      let st;
      try {
        st = await stat(filePath);
      } catch {
        res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
        return;
      }
      if (st.isDirectory()) {
        res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
        return;
      }
      const ext = path.extname(filePath).toLowerCase();
      res.writeHead(200, {
        'Content-Type': MIME[ext] || 'application/octet-stream',
        'Content-Length': st.size,
        'Cache-Control': 'no-cache',
      });
      createReadStream(filePath).pipe(res);
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain' }).end('server error');
    }
  });
}

// Run standalone when invoked directly.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const get = (name, def) => {
    const i = argv.indexOf(name);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
  };
  const root = get('--root', path.resolve(__dirname, '../../build/web'));
  const port = parseInt(get('--port', '0'), 10);
  try {
    statSync(root);
  } catch {
    console.error(`[server] root not found: ${root}`);
    console.error('[server] run scripts/export-web.sh first, or pass --root <dir>.');
    process.exit(2);
  }
  const server = createServer(root);
  server.listen(port, '127.0.0.1', () => {
    const addr = server.address();
    console.log(
      `web-soak-server listening http://127.0.0.1:${addr.port} root=${path.resolve(root)}`,
    );
  });
}
