#!/usr/bin/env node
// Tiny JSON reducer for `vastai … --raw` output, so the bash drivers need no jq.
//
// Reads JSON on STDIN. Modes:
//   pick-offer --max-price <f> --min-disk <gb>
//       Input: the array from `vastai search offers … --raw`.
//       Filters to rentable offers with disk_space >= min-disk AND dph_total <= max-price,
//       sorts ascending by dph_total, prints the cheapest as:
//           "<id> <dph_total> <gpu_name> <disk_space>"
//       Exits 3 if no offer qualifies (so the caller can fail with a clear message).
//
//   field <name>
//       Input: a single object (e.g. `vastai create instance … --raw`).
//       Prints the value of top-level <name> (e.g. new_contract). Exits 3 if absent.
//
//   instance-state <id>
//       Input: the array from `vastai show instances --raw`.
//       Prints the actual_status of the instance whose id == <id> (empty if not found).

import { readFileSync } from 'node:fs';

function readStdin() {
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function parseJson(text) {
  const t = (text || '').trim();
  if (!t) return null;
  try {
    return JSON.parse(t);
  } catch (e) {
    process.stderr.write(`[vastjson] could not parse JSON stdin: ${e}\n`);
    process.exit(2);
  }
}

function argVal(argv, name, def = null) {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
}

const argv = process.argv.slice(2);
const mode = argv[0];
const data = parseJson(readStdin());

if (mode === 'pick-offer') {
  const maxPrice = parseFloat(argVal(argv, '--max-price', 'Infinity'));
  const minDisk = parseFloat(argVal(argv, '--min-disk', '0'));
  if (!Array.isArray(data)) {
    process.stderr.write('[vastjson] pick-offer expects a JSON array of offers\n');
    process.exit(2);
  }
  // Price field: prefer dph_total (total incl. internet); fall back to dph.
  const priceOf = (o) => Number(o.dph_total ?? o.dph);
  const ok = data.filter((o) => {
    if (o == null || typeof o !== 'object') return false;
    const dph = priceOf(o);
    const disk = Number(o.disk_space);
    if (!Number.isFinite(dph) || dph <= 0) return false;
    if (dph > maxPrice) return false;
    if (Number.isFinite(disk) && disk < minDisk) return false;
    // rentable may be true/1/"true"; treat only an explicit falsey as unrentable.
    if (o.rentable === false || o.rentable === 0) return false;
    return true;
  });
  ok.sort((a, b) => priceOf(a) - priceOf(b));
  if (ok.length === 0) process.exit(3);
  const o = ok[0];
  process.stdout.write(
    `${o.id} ${priceOf(o)} ${String(o.gpu_name || '?').replace(/\s+/g, '_')} ${o.disk_space ?? '?'}\n`,
  );
  process.exit(0);
}

if (mode === 'field') {
  const name = argv[1];
  if (data == null || typeof data !== 'object' || Array.isArray(data)) {
    process.stderr.write('[vastjson] field expects a JSON object\n');
    process.exit(2);
  }
  if (!(name in data) || data[name] == null) process.exit(3);
  process.stdout.write(`${data[name]}\n`);
  process.exit(0);
}

if (mode === 'instance-state') {
  const id = String(argv[1]);
  const arr = Array.isArray(data) ? data : (data && Array.isArray(data.instances) ? data.instances : []);
  const inst = arr.find((x) => String(x.id) === id);
  process.stdout.write(inst ? `${inst.actual_status ?? inst.cur_state ?? ''}\n` : '\n');
  process.exit(0);
}

process.stderr.write(`[vastjson] unknown mode: ${mode}\n`);
process.exit(2);
