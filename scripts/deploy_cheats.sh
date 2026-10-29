#!/usr/bin/env bash
# VOXIVERSE — export the Web build with the live feature-flag set switched ON.
#
# The served game world runs with a few hundred GDScript `const` feature flags
# switched ON, while the committed source keeps them at their defaults (false).
# This script recreates that world: it flips the flags in a clean copy of the
# flag files, verifies the flips, exports the Web build, then restores the
# files. The flag list is NOT inlined here; it is read from
#   docs/knowhow/live-flags/live-flags.json
# (recovered from the exported live pack; see docs/knowhow/live-flags/LIVE-FLAGS.md).
#
#   scripts/deploy_cheats.sh --dry-run     # flip + verify in a temp copy, print counts
#   scripts/deploy_cheats.sh               # flip, verify, export-web, revert
#   scripts/deploy_cheats.sh --deploy      # ... and then scripts/deploy.sh --no-build
#   CLITE_FLAGS="FP_X FP_Y" scripts/deploy_cheats.sh   # extra cube_sphere.gd flags ON (A/B arm)
#
# Environment:
#   LIVE_FLAGS_JSON  alternative flag file (default docs/knowhow/live-flags/live-flags.json)
#   CLITE_FLAGS      space-separated extra flags to switch ON in cube_sphere.gd
#   EXPORT_LOG       export log path (default build/export_cheats.log)
#
# Steps (real run):
#   1. refuse if a flag file has uncommitted changes (the restore step would wipe them),
#      then sed `const NAME := false` -> `true` for every flag the JSON lists as live ON
#   2. hard verify: every listed flag is true, every live-OFF const (including the
#      must-stay-OFF set) is still false, and exactly N lines changed
#   3. scripts/export-web.sh, then scan the export log for GDScript parse errors
#      (the Godot export does not fail on them) and check the HTML shell markers
#   4. restore the flag files with `git checkout --` (also on every failure path)
#   5. optional (--deploy): scripts/deploy.sh --no-build
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAGS_JSON="${LIVE_FLAGS_JSON:-${REPO_ROOT}/docs/knowhow/live-flags/live-flags.json}"
CS_FILE="godot/src/cosmos/cube_sphere.gd"
EXPORT_LOG="${EXPORT_LOG:-${REPO_ROOT}/build/export_cheats.log}"

MODE=export
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE=dry ;;
    --deploy)  MODE=deploy ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }
[ -f "${FLAGS_JSON}" ] || die "flag file not found: ${FLAGS_JSON}"
command -v python3 >/dev/null || die "python3 is required to read ${FLAGS_JSON}"

# --- Read the flag list from the JSON ---------------------------------------
# Emits lines: "ON <file> <const>" for flags to switch on (source default false,
# live true) and "OFF <file> <const>" for consts that must stay false.
read_flags() {
  python3 - "${FLAGS_JSON}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
off = set(doc.get('must_stay_off', []))
seen_off = set()
for r in doc['records']:
    if r.get('source_default') is False and r['live_value'] is True:
        print('ON', r['file'], r['const'])
    elif r['live_value'] is False:
        print('OFF', r['file'], r['const'])
        seen_off.add(r['const'])
missing = off - seen_off
if missing:
    sys.exit('must_stay_off names not recorded as live-false: %s' % ' '.join(sorted(missing)))
PY
}
FLAG_LINES="$(read_flags)" || die "could not read ${FLAGS_JSON}"
mapfile -t ON_LINES < <(printf '%s\n' "${FLAG_LINES}" | awk '$1=="ON"{print $2" "$3}')
mapfile -t OFF_LINES < <(printf '%s\n' "${FLAG_LINES}" | awk '$1=="OFF"{print $2" "$3}')
for extra in ${CLITE_FLAGS:-}; do
  [[ "$extra" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad CLITE_FLAGS name: $extra"
  ON_LINES+=("${CS_FILE} ${extra}")
done
mapfile -t FILES < <(printf '%s\n' "${ON_LINES[@]}" | awk '{print $1}' | sort -u)
MUST_STAY_OFF="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["must_stay_off"]))' "${FLAGS_JSON}")"
N_ON=${#ON_LINES[@]}
[ "${N_ON}" -gt 0 ] || die "no flags to switch on"

# `const NAME := false`, `const NAME = false` and `const NAME: bool = false`.
const_re() { printf '^const %s[[:space:]]*(:[[:space:]]*bool[[:space:]]*)?:?=[[:space:]]*' "$1"; }

# apply_flips <root>: flip every listed flag under <root>.
apply_flips() {
  local root="$1" file name
  for entry in "${ON_LINES[@]}"; do
    file="${entry%% *}"; name="${entry#* }"
    sed -i -E "s/($(const_re "${name}"))false\b/\1true/" "${root}/${file}"
  done
}

# verify_flips <root>: hard checks; prints counts; non-zero on any failure.
verify_flips() {
  local root="$1" file name bad=0 changed=0 checked=0 f
  for entry in "${ON_LINES[@]}"; do
    file="${entry%% *}"; name="${entry#* }"
    local hits
    hits="$(grep -cE "$(const_re "${name}")true\b" "${root}/${file}" || true)"
    if [ "${hits}" != "1" ]; then echo "!! NOT SET: ${name} (${file}, ${hits} true defs)" >&2; bad=1; fi
  done
  for entry in "${OFF_LINES[@]}"; do
    file="${entry%% *}"; name="${entry#* }"
    [ -f "${root}/${file}" ] || continue
    checked=$((checked + 1))
    if ! grep -qE "$(const_re "${name}")false\b" "${root}/${file}"; then
      # a CLITE_FLAGS arm may deliberately switch a live-OFF flag on
      case " ${CLITE_FLAGS:-} " in *" ${name} "*) continue ;; esac
      echo "!! NOT OFF: ${name} (${file})" >&2; bad=1
    fi
  done
  for name in ${MUST_STAY_OFF}; do
    if ! grep -qE "$(const_re "${name}")false\b" "${root}/${CS_FILE}"; then
      echo "!! MUST-STAY-OFF flag is not false: ${name}" >&2; bad=1
    fi
  done
  for f in "${FILES[@]}"; do
    local n
    n="$(diff <(git -C "${REPO_ROOT}" show "HEAD:${f}") "${root}/${f}" | grep -c '^>' || true)"
    echo "   ${f}: ${n} lines changed"
    changed=$((changed + n))
  done
  echo "   flags listed ON: ${N_ON}; lines changed: ${changed}; live-OFF consts checked: ${checked}"
  [ "${changed}" -eq "${N_ON}" ] || { echo "!! changed-line count ${changed} != ${N_ON}" >&2; bad=1; }
  # Whole-file cross-check: every bool const the JSON records for these files
  # must now carry exactly its recorded live value (skipped for A/B arms).
  if [ -z "${CLITE_FLAGS:-}" ]; then
    python3 - "${FLAGS_JSON}" "${root}" "${FILES[@]}" <<'PY' || bad=1
import json, os, re, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
root, files = sys.argv[2], set(sys.argv[3:])
rx = re.compile(r'^const\s+([A-Za-z_]\w*)\s*(?::\s*bool\s*)?:?=\s*(true|false)\b')
want = {(r['file'], r['const']): r['live_value'] for r in doc['records'] if r['file'] in files}
have = {}
for f in files:
    for line in open(os.path.join(root, f), encoding='utf-8'):
        m = rx.match(line)
        if m:
            have[(f, m.group(1))] = m.group(2) == 'true'
bad = [k for k, v in want.items() if have.get(k) is not v]
for k in bad:
    print('!! %s %s: file=%s pack=%s' % (k[0], k[1], have.get(k), want[k]), file=sys.stderr)
print('   whole-file match vs pack: %d/%d consts' % (len(want) - len(bad), len(want)))
sys.exit(1 if bad else 0)
PY
  fi
  return "${bad}"
}

# --- Dry run: temp copy only -------------------------------------------------
if [ "${MODE}" = dry ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  for f in "${FILES[@]}"; do
    mkdir -p "${TMP}/$(dirname "${f}")"
    git -C "${REPO_ROOT}" show "HEAD:${f}" > "${TMP}/${f}"
  done
  echo "==> dry run: flipping ${N_ON} flags in a temp copy of HEAD (${#FILES[@]} files)"
  apply_flips "${TMP}"
  if verify_flips "${TMP}"; then
    echo "==> dry run OK: ${N_ON} flags ON, must-stay-OFF (${MUST_STAY_OFF}) false"
    exit 0
  fi
  die "dry run verify FAILED"
fi

# --- Real run ----------------------------------------------------------------
cd "${REPO_ROOT}"
for f in "${FILES[@]}"; do
  git diff --quiet HEAD -- "${f}" \
    || die "${f} has uncommitted changes; commit them first (the restore step would wipe them)"
done
restore() { git -C "${REPO_ROOT}" checkout -- "${FILES[@]}"; }
trap 'restore' EXIT

echo "==> flipping ${N_ON} flags in: ${FILES[*]}"
apply_flips "${REPO_ROOT}"
verify_flips "${REPO_ROOT}" || die "verify FAILED (files restored)"

mkdir -p "$(dirname "${EXPORT_LOG}")"
echo "==> exporting (log: ${EXPORT_LOG})"
if ! "${REPO_ROOT}/scripts/export-web.sh" 2>&1 | tee "${EXPORT_LOG}"; then
  die "export-web.sh failed (files restored)"
fi
if grep -qiE 'Parse Error|SCRIPT ERROR|Cannot find member' "${EXPORT_LOG}"; then
  grep -iE 'Parse Error|SCRIPT ERROR|Cannot find member' "${EXPORT_LOG}" | head -20 >&2
  die "export log has GDScript errors; the build would be broken"
fi
HTML="${REPO_ROOT}/build/web/index.html"
for marker in VOXIVERSE_BOOT_SPLASH_MARKER engine.startGame 'Starting engine'; do
  grep -q "${marker}" "${HTML}" || die "index.html is missing the shell marker '${marker}'"
done

restore
trap - EXIT
git diff --quiet HEAD -- "${FILES[@]}" || die "flag files did not restore cleanly"
echo "==> export OK; flag files restored"

if [ "${MODE}" = deploy ]; then
  "${REPO_ROOT}/scripts/deploy.sh" --no-build
fi
