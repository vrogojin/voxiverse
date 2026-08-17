class_name ObjectLod
extends RefCounted
## COSMOS-OBJECT-LOD P0 (docs/COSMOS-OBJECT-LOD-DESIGN.md) — the pure-static LOD SELECTION LAW for discrete
## physical objects (VoxelBody debris now; ships/stations/asteroids later). It GENERALISES the shipped
## multi-body angular law (BodyLod, cosmos/body_lod.gd) from celestial bodies to arbitrary objects: same
## px-per-radian K_px, same projected-size primitive, same one-sided hysteresis, same "swap fires ≤ its own
## screen-space threshold ⇒ sub-pixel no-pop" guarantee. NO engine singletons, NO nodes, NO renderer — every
## function is pure math so the gate (verify_object_lod.gd) certifies it FLAT. Reachable only behind
## CubeSphere.FP_OBJ_LOD; the renderer tiers that consume this law arrive in P1..P3, all default-OFF.
##
## THE LAW (all lengths in blocks; all screen quantities in DEVICE px — DPR-corrected once at init + on resize):
##   K_px       = viewport_height_device_px / (2·tan(fov/2))      # px per radian; LIVE Camera3D.fov (zoom-aware)
##   proj_px    = 2·r / d · K_px                                  # the object's projected disc Ø in device px
##   sse_px(e)  = e / d · K_px                                    # a representation's silhouette error in device px
## Pick the COARSEST representation whose sse_px ≤ TAU_OBJ; below P_POINT the object is a dot (clamped for
## space, dither-culled for debris). Switch distance is closed-form: d = e·K_px / TAU_OBJ.

# ── Representations, coarse → fine (increasing detail = decreasing silhouette error e) ────────────────────
const REP_DOT := 0        # unlit point/beacon (1 MultiMesh); e = r        (whole object → a point)
const REP_CARD := 1       # camera-facing cross+cap cards (1 MultiMesh);   e ≈ r/2
const REP_MESH := 2       # StructDecimator mesh at pitch 2^k;             e ≈ pitch (the `pitch` field carries k's 2^k)
const REP_FULL := 3       # the object's own full VoxelBody mesh;          e = 0 (exact)
const REP_NAMES := ["DOT", "CARD", "MESH", "FULL"]

# ── Object classes (cull policy diverges) ────────────────────────────────────────────────────────────────
const CLASS_DEBRIS := 0   # VoxelBody clutter — dither-fades out below CULL_DEBRIS_PX
const CLASS_SPACE := 1    # ships/stations/asteroids — NEVER hard-culled; clamps to a P_POINT beacon dot

# ── Thresholds (mirror BodyLod so the two ladders agree at the seam) ─────────────────────────────────────
const P_POINT := 2.0          # device px: below this the object is a dot (BodyLod P_POINT)
const TAU_OBJ := 1.0          # device px: a representation may be used only while its sse ≤ this (BodyLod TAU_POP)
const HYST := 0.25            # one-sided sticky band (BodyLod HYST) — promote at the knee, demote HYST below it
const CULL_DEBRIS_PX := 0.5   # device px: debris fully faded out (space objects never reach here)

# ── Mesh-rung sizing (auto LOD-step count from object extent) ────────────────────────────────────────────
const MESH_MIN_EXTENT := 16   # blocks: below this an object skips the decimated-mesh rung (FULL → CARD → DOT)
const MESH_STEP_MAX := 8       # cap on decimated-mesh steps (a 512-block station → 7; keeps the ladder bounded)

# ── Never-OOM budget (P1+ consumes this; the LAW that PICKS the tier is pure + gate-certified here) ───────
const OBJ_LOD_BYTES_MAX := 16 * 1024 * 1024   # hard compile-time ceiling the gate proves the worst state at
const BUDGET_TIERS_MB := [2, 4, 8, 16]        # boot-time proxy-selected ladder (small → large); DEMOTE-only mid-session
const MESH_CAP := 16          # max simultaneous decimated meshes (StructDecimator instances)
const CARD_TILE_CAP := 256    # max UNIQUE card tiles (archetype-tinted fallback beyond — avoids per-rev atlas blowup)
const CARD_INST_CAP := 2048   # max card MultiMesh instances
const DOT_CAP := 4096         # max dot MultiMesh instances

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# Angular-size primitives (identical to BodyLod.k_px / ang_px / relief_px — the generalisation is only that r
# and e are now arbitrary-object quantities, not per-celestial-body table constants).
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────

## px per radian for a `viewport_h_px`-tall viewport at vertical field-of-view `fov_rad`. Feed the LIVE
## Camera3D.fov (deg→rad) — NOT a nominal constant — so a zoom/telescope promotes distant objects for free.
static func k_px(viewport_h_px: float, fov_rad: float) -> float:
	var t := tan(fov_rad * 0.5)
	if t <= 0.0:
		return 0.0
	return viewport_h_px / (2.0 * t)

## The object's projected disc DIAMETER in device px at camera distance d (blocks). 0 if d ≤ 0.
static func proj_px(r_obj: float, d: float, kpx: float) -> float:
	if d <= 0.0:
		return 0.0
	return 2.0 * r_obj / d * kpx

## A representation's silhouette error projected to device px at distance d. 0 for the exact full mesh.
static func sse_px(e_rep: float, d: float, kpx: float) -> float:
	if d <= 0.0:
		return 0.0
	return e_rep / d * kpx

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# Ladder sizing — the number of decimated-mesh steps (and their pitches) falls out of the object's extent.
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────

static func _log2i(v: float) -> int:
	if v <= 1.0:
		return 0
	return int(floor(log(v) / log(2.0)))

## The decimated-mesh pitches (COARSE → fine, each 2^k) for an object of `extent` blocks. Empty below
## MESH_MIN_EXTENT (small objects go FULL → CARD → DOT with no mesh rung). The coarsest pitch is bounded so
## its error ≈ r/2 (≈ the CARD rung), giving a clean CARD↔MESH seam; count is capped at MESH_STEP_MAX.
static func mesh_pitches(extent: float) -> Array:
	if extent < float(MESH_MIN_EXTENT):
		return []
	var k := clampi(_log2i(extent) - 2, 1, MESH_STEP_MAX)   # extent 16→1 step(2), 30→2(2,4), 512→7(2..128)
	var out: Array = []
	for i in range(k, 0, -1):     # 2^k (coarsest) down to 2^1 (finest mesh)
		out.append(1 << i)
	return out

## The auto LOD-step count (decimated-mesh rungs) for an object of `extent` blocks — the "decide from size" rule.
static func step_count(extent: float) -> int:
	return mesh_pitches(extent).size()

## The silhouette error e (blocks) of a representation. r = object bounding radius (½·extent); pitch only used
## by REP_MESH. CARD ≈ r/2, DOT = r (the whole object collapses to a point), FULL = 0.
static func rep_error(rep: int, pitch: int, r: float) -> float:
	match rep:
		REP_FULL:
			return 0.0
		REP_MESH:
			return float(pitch)
		REP_CARD:
			return r * 0.5
		_:
			return r          # REP_DOT

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# Selection — stateless (rung_raw) and latched/anti-thrash (rung_hyst).
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────

## The coarse→fine candidate list (excluding DOT) for an object of `extent`: CARD, then each mesh pitch
## (coarse→fine), then FULL. Each entry is [rep, pitch].
static func _candidates(extent: float) -> Array:
	var out: Array = [[REP_CARD, 0]]
	for c in mesh_pitches(extent):
		out.append([REP_MESH, c])
	out.append([REP_FULL, 0])
	return out

## The coarsest NON-DOT representation whose sse ≤ TAU_OBJ (the disc is already known to be ≥ its dot knee).
static func _select_nondot(r: float, extent: float, d: float, kpx: float, p: float) -> Dictionary:
	for cand in _candidates(extent):
		var e := rep_error(cand[0], cand[1], r)
		var s := sse_px(e, d, kpx)
		if s <= TAU_OBJ:
			return {"rep": cand[0], "pitch": cand[1], "proj": p, "sse": s}
	return {"rep": REP_FULL, "pitch": 0, "proj": p, "sse": 0.0}   # nearest → exact

## The bare law: DOT when the disc is sub-P_POINT, else the COARSEST representation whose sse ≤ TAU_OBJ.
## Returns {"rep", "pitch", "proj", "sse"}. r = ½·extent.
static func rung_raw(r: float, extent: float, d: float, kpx: float) -> Dictionary:
	var p := proj_px(r, d, kpx)
	if p < P_POINT:
		return {"rep": REP_DOT, "pitch": 0, "proj": p, "sse": sse_px(rep_error(REP_DOT, 0, r), d, kpx)}
	return _select_nondot(r, extent, d, kpx, p)

## Latched form (BodyLod.tier_hyst structure): a one-sided sticky DOT band. Stay a disc (non-dot) until the
## projection falls below P_POINT·(1−HYST); promote OUT of dot only once it reaches P_POINT. The dot decision
## is made HERE (not delegated to rung_raw, whose hard P_POINT floor would defeat the band). `current_rep` is
## the caller's previously-latched rep.
static func rung_hyst(current_rep: int, r: float, extent: float, d: float, kpx: float) -> Dictionary:
	var p := proj_px(r, d, kpx)
	var dot_knee := P_POINT if current_rep == REP_DOT else (P_POINT * (1.0 - HYST))
	if p < dot_knee:
		return {"rep": REP_DOT, "pitch": 0, "proj": p, "sse": sse_px(rep_error(REP_DOT, 0, r), d, kpx)}
	return _select_nondot(r, extent, d, kpx, p)

## The screen-space delta (device px) a DOT⇄non-DOT swap introduces AT distance d — bounded by P_POINT because
## the swap fires there. Used by the gate to prove the handover is sub-pixel (the no-pop invariant).
static func swap_delta_px(r: float, d: float, kpx: float) -> float:
	return proj_px(r, d, kpx)

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# Cull / beacon policy — the class-dependent tail of the ladder.
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────

## What to do with a sub-P_POINT object. Returns {"draw", "fade", "dot_px"}:
##  DEBRIS: fades linearly over [CULL_DEBRIS_PX, P_POINT]; draw=false (fully culled) below CULL_DEBRIS_PX.
##  SPACE : never culled — clamps the drawn dot to P_POINT (the beacon floor); fade stays 1.0. Brightness ∝ p²
##          (a shrinking sub-pixel emitter conserves flux) is applied by the renderer using the returned proj.
static func cull(obj_class: int, p: float) -> Dictionary:
	if p >= P_POINT:
		return {"draw": true, "fade": 1.0, "dot_px": p}
	if obj_class == CLASS_SPACE:
		return {"draw": true, "fade": 1.0, "dot_px": P_POINT}          # beacon floor — never disappears
	if p <= CULL_DEBRIS_PX:
		return {"draw": false, "fade": 0.0, "dot_px": 0.0}            # debris gone
	var f := (p - CULL_DEBRIS_PX) / (P_POINT - CULL_DEBRIS_PX)         # linear dither-fade
	return {"draw": true, "fade": clampf(f, 0.0, 1.0), "dot_px": maxf(p, 1.0)}

## Beacon brightness multiplier for a sub-pixel space object at projected size `p` (device px): flux-conserving
## p² falloff, normalised to 1.0 at the P_POINT floor and never above it. Photometrically the right law for an
## emitter that has shrunk below a pixel (Elite/KSP beacon pattern).
static func beacon_brightness(p: float) -> float:
	if p >= P_POINT:
		return 1.0
	var r := p / P_POINT
	return clampf(r * r, 0.0, 1.0)

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# Never-OOM budget — the boot-time proxy → ledger-tier selection (pure; the renderer applies it in P1+).
# WebGL2 cannot read VRAM and over-allocation LOSES the GL context, so we DO NOT probe-grow: we pick a tier up
# front from coarse proxies and may only DEMOTE mid-session. The gate certifies the pick is monotone + capped.
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────

## Boot ledger budget in BYTES from device proxies:
##   gpu_tier   : 0 weak / 1 mid / 2 strong  (caller derives from WEBGL_debug_renderer_info GPU string)
##   dev_mem_gb : navigator.deviceMemory (GB), 0 if unknown
##   cores      : navigator.hardwareConcurrency, 0 if unknown
## Result ∈ {2,4,8,16} MB, never above OBJ_LOD_BYTES_MAX. Every proxy can only lower the pick (never-OOM-safe).
static func budget_bytes(gpu_tier: int, dev_mem_gb: float, cores: int) -> int:
	var mb: int = [2, 8, 16][clampi(gpu_tier, 0, 2)]
	if dev_mem_gb > 0.0:
		var by_mem := 2 if dev_mem_gb <= 2.0 else (8 if dev_mem_gb <= 4.0 else 16)
		mb = mini(mb, by_mem)
	if cores > 0 and cores <= 2:
		mb = mini(mb, 4)
	mb = _snap_tier(mb)
	return mini(mb * 1024 * 1024, OBJ_LOD_BYTES_MAX)

## Snap an MB value DOWN to the largest budget tier ≤ it (never rounds up — never-OOM).
static func _snap_tier(mb: int) -> int:
	var out: int = BUDGET_TIERS_MB[0]
	for t in BUDGET_TIERS_MB:
		if t <= mb:
			out = t
	return out
