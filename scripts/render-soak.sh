#!/usr/bin/env bash
# ============================================================================================
# Tier-A NATIVE RENDERED SOAK runner (task #104).
#
# Boots the REAL game (res://scenes/main.tscn) under a virtual X server (Xvfb) + Mesa software GL
# (llvmpipe/swrast), renders REAL frames through the SAME GL Compatibility backend web ships,
# walks a fixed path, records the frame-time + render-HEAP series, saves periodic screenshots, and
# perceptually golden-compares them — catching the class of failures --headless is blind to:
#   * broken/failed shader compile on the Compatibility backend,
#   * disappeared geometry (black / empty frame),
#   * heap-under-render runaway (texture + framebuffer VRAM headless never allocates).
#
# The frame-TIMING numbers are CPU-rendered (llvmpipe) and NON-REPRESENTATIVE of real GPU/browser
# FPS — they exist only to catch a pathological stall. The REAL signals are: rendered-vs-black,
# golden perceptual diff, and the heap peaks.
#
# USAGE:
#   scripts/render-soak.sh                 # build image if needed, run the soak, golden-compare
#   scripts/render-soak.sh --generate-goldens   # run, then ADOPT the captures as the committed goldens
#   scripts/render-soak.sh --rebuild-image # force-rebuild the runtime docker image first
#   scripts/render-soak.sh --no-compare    # run the soak only, skip the golden-compare
#
# EXIT: 0 = clean rendered walk (+ golden-compare pass); nonzero = render failure, black frame,
#       heap over ceiling, or gross visual regression vs goldens.
# ============================================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="voxiverse/render-soak:1"
DOCKERFILE="$REPO/scripts/render-soak.Dockerfile"
BIN="$REPO/docker/engine/bin/godot.linuxbsd.editor.x86_64"
OUT="$REPO/build/soak"          # gitignored — render outputs (PNGs, CSV, JSON) land here
FRAMES="$OUT/frames"
GOLDENS="$REPO/godot/test/soak_goldens"   # committed — small downscaled reference frames
RES="1280x720"

# perceptual golden thresholds — GENEROUS (software raster varies run-to-run); fail only on GROSS regression.
GOLDEN_W=160                    # goldens are downscaled to this width (tiny to commit; structure still compares)
RMSE_MAX="0.30"                 # normalised RMSE ceiling vs golden (0=identical, 1=inverse). Loose on purpose.

GEN_GOLDENS=0
REBUILD_IMAGE=0
DO_COMPARE=1
for a in "$@"; do
  case "$a" in
    --generate-goldens) GEN_GOLDENS=1 ;;
    --rebuild-image)    REBUILD_IMAGE=1 ;;
    --no-compare)       DO_COMPARE=0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# --- preconditions ---------------------------------------------------------------------------
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: native editor binary not found at $BIN" >&2
  echo "       build it first: scripts/build.sh   (Tier-A needs the custom native engine)." >&2
  exit 3
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required (software-GL + Xvfb + imagemagick run inside a container)." >&2
  exit 3
fi

# --- build the runtime image if missing (or forced) — seconds, NOT the ~24-min engine build. --
if [[ "$REBUILD_IMAGE" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> building render-soak runtime image ($IMAGE) …"
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$REPO/scripts"
fi

mkdir -p "$FRAMES"
rm -f "$FRAMES"/frame_*.png "$OUT"/soak_render_series.csv "$OUT"/soak_render.json 2>/dev/null || true

# --- run the soak: Xvfb virtual display + llvmpipe software GL, real opengl3 driver, real frames. ---
# SOAK_OUT is an absolute container path (bind-mounted to $FRAMES) so PNGs/CSV land on the host.
echo "==> running rendered soak (Xvfb + llvmpipe, driver=opengl3, res=$RES) …"
set +e
docker run --rm \
  -v "$REPO:/work" -w /work \
  -e SOAK_OUT=/work/build/soak/frames \
  "$IMAGE" -lc '
    set -e
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_GL_VERSION_OVERRIDE=3.3
    echo "-- glxinfo (software renderer identification) --"
    xvfb-run -a -s "-screen 0 '"$RES"'x24" glxinfo 2>/dev/null | grep -iE "OpenGL renderer|OpenGL version" || echo "(glxinfo unavailable)"
    echo "-- launching godot rendered soak --"
    xvfb-run -a -s "-screen 0 '"$RES"'x24" \
      docker/engine/bin/godot.linuxbsd.editor.x86_64 --path godot \
        --rendering-driver opengl3 --resolution '"$RES"' \
        --script res://src/tools/soak_render.gd
  '
SOAK_RC=$?
set -e
echo "==> soak exit code: $SOAK_RC"

SHOTS=$(ls "$FRAMES"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
echo "==> captured $SHOTS screenshot(s) in $FRAMES"
if [[ "$SOAK_RC" != "0" ]]; then
  echo "ERROR: the rendered soak reported a failure (see [SOAK-RENDER] output above)." >&2
  exit "$SOAK_RC"
fi

# --- generate-goldens mode: adopt the captures (downscaled) as the committed reference set. --------
if [[ "$GEN_GOLDENS" == "1" ]]; then
  echo "==> --generate-goldens: writing downscaled goldens to $GOLDENS"
  mkdir -p "$GOLDENS"
  rm -f "$GOLDENS"/frame_*.png 2>/dev/null || true
  docker run --rm -v "$REPO:/work" -w /work "$IMAGE" -lc '
    set -e
    for f in build/soak/frames/frame_*.png; do
      [ -e "$f" ] || continue
      out="godot/test/soak_goldens/$(basename "$f")"
      convert "$f" -resize '"$GOLDEN_W"'x "$out"
    done
    ls -la godot/test/soak_goldens/
  '
  echo "==> goldens generated. Review, then commit the small PNGs under $GOLDENS."
  exit 0
fi

# --- golden-compare: perceptual RMSE at a GENEROUS threshold; fail only on gross visual regression. --
if [[ "$DO_COMPARE" == "0" ]]; then
  echo "==> --no-compare: skipping golden-compare."
  exit 0
fi
if [[ ! -d "$GOLDENS" ]] || [[ -z "$(ls "$GOLDENS"/frame_*.png 2>/dev/null)" ]]; then
  echo "==> NOTE: no committed goldens in $GOLDENS — skipping golden-compare (first run)."
  echo "          Generate them once with:  scripts/render-soak.sh --generate-goldens"
  echo "          The in-engine black-frame detector + heap ceilings already gated this run."
  exit 0
fi

echo "==> golden-compare (downscale to ${GOLDEN_W}px, normalised RMSE ≤ $RMSE_MAX) …"
set +e
docker run --rm -v "$REPO:/work" -w /work "$IMAGE" -lc '
  set -u
  fail=0; compared=0
  for g in godot/test/soak_goldens/frame_*.png; do
    [ -e "$g" ] || continue
    base="$(basename "$g")"
    cap="build/soak/frames/$base"
    if [ ! -e "$cap" ]; then
      echo "  MISS: capture for golden $base not produced this run"; fail=1; continue
    fi
    # downscale the capture to the golden size, then normalised RMSE.
    tmp="/tmp/$base"
    convert "$cap" -resize '"$GOLDEN_W"'x "$tmp"
    rmse="$(compare -metric RMSE "$tmp" "$g" null: 2>&1 | sed -E "s/.*\(([0-9.]+)\).*/\1/")"
    compared=$((compared+1))
    awk -v r="$rmse" -v m='"$RMSE_MAX"' -v b="$base" '\''BEGIN{
      if (r+0>m+0){ printf "  REGRESSION: %s normalised RMSE %.4f > %.2f\n", b, r, m; exit 3 }
      else       { printf "  ok: %s RMSE %.4f\n", b, r }
    }'\''
    [ $? -ne 0 ] && fail=1
  done
  echo "  compared $compared frame(s)"
  exit $fail
'
CMP_RC=$?
set -e
if [[ "$CMP_RC" != "0" ]]; then
  echo "ERROR: golden-compare found a GROSS visual regression (see above)." >&2
  exit "$CMP_RC"
fi
echo "==> golden-compare PASS."
echo "==> Tier-A rendered soak: PASS"
