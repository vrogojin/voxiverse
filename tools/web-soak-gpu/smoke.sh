#!/usr/bin/env bash
# Local CPU-fallback smoke for the web-soak harness (NO GPU box required).
#
# This is NOT the real perf test — it forces the SwiftShader software rasteriser so
# the harness plumbing (server COOP/COEP, engine boot, [PERF] scrape, heap API, soak
# driving, the real-GPU gate) can be proven on any machine. The real measurement is
# `node soak.mjs --gpu` under xvfb on a T4 box (see README).
#
# Runs, in order:
#   1. server header check (curl COOP/COEP)
#   2. GPU-gate self-test          — SwiftShader detected, gate would reject   (exit 0)
#   3. GPU-gate strict fail         — --require-gpu on SwiftShader              (exit 1 EXPECTED)
#   4. full software smoke          — boot + [PERF] + heap + walk               (exit 0)
set -u
cd "$(dirname "$0")"

echo "== 1. static server COOP/COEP headers =="
node server.mjs --port 8991 & SRV=$!
sleep 1.5
curl -sI http://127.0.0.1:8991/index.html | grep -iE "cross-origin-(opener|embedder)"
curl -sI http://127.0.0.1:8991/index.wasm | grep -iE "content-type|cross-origin-embedder"
kill "$SRV" 2>/dev/null

echo "== 2. GPU-gate self-test (SwiftShader must be REJECTED; run exits 0) =="
node soak.mjs --cpu-fallback; echo "exit=$?"

echo "== 3. GPU-gate STRICT (SwiftShader on --require-gpu must exit 1) =="
node soak.mjs --cpu-fallback --require-gpu; echo "exit=$? (1 = correct)"

echo "== 4. full software smoke (boot + PERF + heap + walk; exit 0) =="
node soak.mjs --cpu-fallback --allow-software --duration "${1:-20}" --shots 2; echo "exit=$?"
