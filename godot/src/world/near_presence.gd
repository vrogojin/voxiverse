class_name NearPresence
extends RefCounted
## COSMOS FARTREE-ALIGN §5 (docs/COSMOS-FARTREE-ALIGN-DESIGN.md) — the SHARED near-mesh-presence predicate.
## Answers ONE question, tri-state, for a fid-lattice box: is facet `fid`'s NEAR voxel field actually meshed over it?
## Owned by task #120 (far-tree handoff cull, implements first); task #121 (far structures, COSMOS-STRUCTURES-DESIGN
## §7.3) reuses it verbatim with its own footprint box + its own hysteresis policy. This module holds NO state —
## hysteresis (HIDE/SHOW streaks, UNKNOWABLE-never-flips) is CONSUMER policy; the shared law every consumer obeys is
## the tri-state semantics below.
##
## `world` is the module_world node (WorldManager passes it through a thin wrapper; null / a fallback world ⇒
## UNKNOWABLE everywhere ⇒ the consumer degrades to its distance band, never worse than shipped). Duck-typed via
## has_method so a world missing the probe never returns a silent false.
##
## SEMANTICS (§5.1) — evaluation is COVERED-FIRST (load-bearing: the double-render band lives in the chunk-quantised
## shell [reach, reach+32] where columns CAN be meshed; a positive is_area_meshed is trustworthy UNCONDITIONALLY, so
## it must be tested BEFORE the radius gate or that shell would latch UNKNOWABLE and never cull where the bug is):
##   1. Y-clamp `box` into TerrainConfig.meshed_slab_y() (the bounds slab every terrain is clamped to). If the clamp
##      EMPTIES the box (fully outside the slab) → NOT_COVERED, DEFINITIVELY (the near field can never mesh it — the
##      far impostor must show forever). This also excludes the FP_APPLIED_PROBE_SLAB dead-latch class by construction
##      (is_area_meshed never clips to bounds, so an unclamped box dead-latches false forever).
##   2. Probe the clamped box (skin_near_meshed → godot_voxel is_area_meshed, resolves the owning pool slot — active
##      OR FP_NB_FULLRES neighbour). TRUE → COVERED, at ANY distance.
##   3. Only a NEGATIVE needs the live-reach gate: if the clamped box lies fully within the live streamable band
##      (meshed_band_y folds in min(viewer_view_distance, pool_view(active)) — never a hardcoded 128) yet is not
##      meshed, it is a REAL no → NOT_COVERED; if it is outside that band, "not meshed yet/here" can't be told from
##      "will never mesh" → UNKNOWABLE.
##   4. No world / probe method missing → UNKNOWABLE (explicit, never a silent false).
##
## Pure read (no streaming/apply cost); consumers may call it every step for a change fingerprint.

const COVERED := 1
const NOT_COVERED := 0
const UNKNOWABLE := -1

static func covered(world, fid: int, box: AABB) -> int:
	if world == null:
		return UNKNOWABLE
	# Step 1 — slab clamp; empty clamp ⇒ NOT_COVERED (never meshable; excludes the is_area_meshed dead-latch class).
	var slab: Vector2 = TerrainConfig.meshed_slab_y()
	var lo := maxf(box.position.y, slab.x)
	var hi := minf(box.position.y + box.size.y, slab.y)
	if lo >= hi:
		return NOT_COVERED
	var clamped := AABB(Vector3(box.position.x, lo, box.position.z), Vector3(box.size.x, hi - lo, box.size.z))
	# Step 2 — COVERED-first probe (positive is_area_meshed is a fact, trustworthy at any distance).
	if not world.has_method("skin_near_meshed"):
		return UNKNOWABLE
	if bool(world.call("skin_near_meshed", fid, clamped)):
		return COVERED
	# Step 3 — negative: distinguish "inside the live reach, a real no" from "beyond reach, can't tell". meshed_band_y
	# is the ONE derivation of the engine's live streamable vertical band (min(viewer_view_distance, pool_view(active))).
	if not world.has_method("meshed_band_y"):
		return UNKNOWABLE
	var band: Vector2 = world.call("meshed_band_y", (lo + hi) * 0.5)
	if lo >= band.x and hi <= band.y:
		return NOT_COVERED
	return UNKNOWABLE
