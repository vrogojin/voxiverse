extends SceneTree
## COSMOS PLANET-VIEW P4 gate (docs/COSMOS-PLANET-VIEW-DESIGN.md §3(A)/P4: FP_FAR_SKIN_FINE). Sharpen the blotchy far-orbit
## planet skin by making the ALREADY-BAKED close-up (finer 128²/facet) skin VISIBLE at far-orbit for the sub-camera disc,
## bounded to FAR_SKIN_FINE_MAX facets and to a measured byte ceiling. Reuses the close-up array/bake/worker/ledger wholesale
## (requires FP_FACET_TEX_CLOSEUP) — ZERO new textures. This gate asserts the PURE, headless-testable parts (byte ledger +
## finer-page dims + the bounded sub-camera selection) unconditionally, then the DRIVER behaviour when the flags are sed-on:
##
##   G-FSF-BYTES   — the orbit fine WORKING-SET byte ledger. fine_peak_bytes(FAR_SKIN_FINE_MAX, CLOSEUP_TEXELS) — the same
##                   per-layer accounting total_bytes() uses — is ≤ FAR_SKIN_FINE_BYTES_MAX (the NEVER-OOM ceiling, ~+2 MB),
##                   and the whole skin ledger (base + close-up pool + band + fine) stays < 40 MB (the combined cap).
##   G-FSF-DIMS    — the fine page is genuinely FINER: CLOSEUP_TEXELS ≥ 2·BASE_TEXELS (here 128 vs 16 = 8×), so a facet-edge
##                   ground pitch shrinks from ≈ 26 blocks/texel (base) to ≈ 3.3 (fine) — coastlines sharpen.
##   G-FSF-SELECT  — the bounded sub-camera selection. fine_top_n(scored, max_n) keeps ≤ max_n entries, exactly the HIGHEST
##                   scores (nearest the sub-point), and is order-independent — the finer set can never exceed the cap.
##   G-FSF-OFF     — byte-identity companion: with FP_FAR_SKIN_FINE off (or close-up off) a baker's fine tier is INERT —
##                   fine_on() false, fine_working_bytes() == 0, fine_orbit_active(true, far) false. (FLAT 6042/0 is the proof.)
##   G-FSF-ORBIT   — (flags on) settled at far-orbit (off-surface, cam_dist > CLOSEUP_FAR) the fine disc promotes: residency
##                   is > 0 and ≤ FAR_SKIN_FINE_MAX, every resident lies within FAR_SKIN_FINE_CAP_DEG of the sub-camera axis,
##                   and fine_working_bytes() ≤ FAR_SKIN_FINE_BYTES_MAX (the cap binds on REAL layer bytes).
##   G-FSF-SURFACE — (flags on) the fine promotion is ORBIT-ONLY: fine_orbit_active is false on the surface and below
##                   CLOSEUP_FAR (the shipped near close-up path runs there, unchanged) — "empty off the flag / on the surface".

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_far_skin_fine (PLANET-VIEW P4 / FP_FAR_SKIN_FINE) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var fine := CubeSphere.FP_FAR_SKIN_FINE
	var cu_on := CubeSphere.FP_FACET_TEX_CLOSEUP
	var tex_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE
	print("  flags FP_FAR_SKIN_FINE=%s FP_FACET_TEX_CLOSEUP=%s FP_FACET_TEX+ABS=%s, spawn facet=%d (K=%d, R=%.0f)"
		% [str(fine), str(cu_on), str(tex_on), fid, FA.K, FA.R_BLOCKS])
	print("  consts FAR_SKIN_FINE_MAX=%d FAR_SKIN_FINE_CAP_DEG=%.1f FAR_SKIN_FINE_BYTES_MAX=%.2f MB CLOSEUP_TEXELS=%d BASE_TEXELS=%d"
		% [CubeSphere.FAR_SKIN_FINE_MAX, CubeSphere.FAR_SKIN_FINE_CAP_DEG,
			float(CubeSphere.FAR_SKIN_FINE_BYTES_MAX) / 1048576.0, CubeSphere.CLOSEUP_TEXELS, FacetTexBaker.BASE_TEXELS])

	_gate_bytes()
	_gate_dims()
	_gate_select()
	_gate_off(fid)
	if fine and cu_on and tex_on:
		_gate_orbit(fid)
		_gate_surface(fid)
	else:
		print("  (DRIVER path OFF — G-FSF-ORBIT/SURFACE need FP_FAR_SKIN_FINE + FP_FACET_TEX_CLOSEUP + FP_FACET_TEX + FP_SHELL_ABSOLUTE on)")
		print("  (OFF-identity is the FLAT verify_feature 6042/0 companion — the fine orbit path is never entered off the flag)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-FSF-BYTES: the orbit fine working-set byte ledger ≤ ceiling; combined skin ledger < 40 MB -------------------
func _gate_bytes() -> void:
	var peak := FacetTexBaker.fine_peak_bytes(CubeSphere.FAR_SKIN_FINE_MAX, CubeSphere.CLOSEUP_TEXELS)
	_ok(peak <= CubeSphere.FAR_SKIN_FINE_BYTES_MAX,
		"G-FSF-BYTES: orbit fine working-set peak = %.3f MB ≤ FAR_SKIN_FINE_BYTES_MAX %.2f MB (NEVER-OOM ceiling, real layer bytes)"
		% [float(peak) / 1048576.0, float(CubeSphere.FAR_SKIN_FINE_BYTES_MAX) / 1048576.0])
	# Combined skin ledger upper bound: base pages (6×384²·RGBA8·×1.333 + 6 CPU) + full close-up pool + RG8 band + the fine
	# working-set — all fixed-size. Compute a conservative sum from the consts and assert the design's < 40 MB combined cap.
	var page := FA.K * FacetTexBaker.BASE_TEXELS
	var page_px := page * page * 4
	var base_bytes := 6 * page_px + (6 * page_px * 4) / 3                    # CPU staging + GPU (+mip tail)
	var cu_lpx := CubeSphere.CLOSEUP_TEXELS * CubeSphere.CLOSEUP_TEXELS * 4
	var cu_bytes := CubeSphere.CLOSEUP_MAX * (cu_lpx + (cu_lpx * 4) / 3)     # the WHOLE close-up pool (fine reuses it)
	var band_bytes := CubeSphere.BAND_LAYERS * CubeSphere.BAND_TEXELS * CubeSphere.BAND_TEXELS * 2  # RG8 shot band
	var combined := base_bytes + cu_bytes + band_bytes + peak
	_ok(combined < 40 * 1024 * 1024,
		"G-FSF-BYTES: combined skin ledger ≈ %.2f MB < 40 MB (base %.1f + close-up pool %.1f + band %.1f + fine %.2f)"
		% [float(combined) / 1048576.0, float(base_bytes) / 1048576.0, float(cu_bytes) / 1048576.0,
			float(band_bytes) / 1048576.0, float(peak) / 1048576.0])
	# The fine set is a BOUNDED SUBSET of the close-up pool — the cap never exceeds the pool it reuses.
	_ok(CubeSphere.FAR_SKIN_FINE_MAX <= CubeSphere.CLOSEUP_MAX,
		"G-FSF-BYTES: FAR_SKIN_FINE_MAX %d ≤ CLOSEUP_MAX %d — the orbit fine set fits inside the reused close-up layer pool"
		% [CubeSphere.FAR_SKIN_FINE_MAX, CubeSphere.CLOSEUP_MAX])

# --- G-FSF-DIMS: the fine page is genuinely finer than the base skin ----------------------------------------------
func _gate_dims() -> void:
	_ok(CubeSphere.CLOSEUP_TEXELS >= 2 * FacetTexBaker.BASE_TEXELS,
		"G-FSF-DIMS: fine page %d texels/facet ≥ 2× base %d (%.1f×) — coastlines sharpen (≈ %.1f → ≈ %.1f blocks/texel at edge ≈ %.0f)"
		% [CubeSphere.CLOSEUP_TEXELS, FacetTexBaker.BASE_TEXELS,
			float(CubeSphere.CLOSEUP_TEXELS) / float(FacetTexBaker.BASE_TEXELS),
			417.0 / float(FacetTexBaker.BASE_TEXELS), 417.0 / float(CubeSphere.CLOSEUP_TEXELS), 417.0])

# --- G-FSF-SELECT: the bounded sub-camera top-N selection ---------------------------------------------------------
func _gate_select() -> void:
	# A synthetic {fid: score} (score larger ⇒ nearer). fine_top_n must keep exactly the max_n highest, bounded, order-free.
	var scored := {}
	for i in range(40):
		scored[i] = float(i) * 0.01          # 0.00 .. 0.39 — id 39 is nearest
	var maxn := 13
	var top := FacetTexBaker.fine_top_n(scored, maxn)
	_ok(top.size() == maxn, "G-FSF-SELECT: fine_top_n keeps exactly max_n = %d of %d candidates (bounded, never exceeds the cap)" % [top.size(), scored.size()])
	# The kept set must be the 13 highest scores: ids 27..39.
	var all_top := true
	for fid in top.keys():
		if int(fid) < 40 - maxn:
			all_top = false
	_ok(all_top, "G-FSF-SELECT: fine_top_n keeps the HIGHEST-score (nearest sub-camera) facets — ids 27..39, none farther")
	# Under-cap: fewer candidates than the cap pass through unchanged (no spurious growth).
	var small := {5: 0.9, 6: 0.8}
	var st := FacetTexBaker.fine_top_n(small, maxn)
	_ok(st.size() == 2 and st.has(5) and st.has(6),
		"G-FSF-SELECT: below the cap the whole set passes through (%d ≤ %d), unchanged" % [st.size(), maxn])

# --- G-FSF-OFF: fine tier inert off the flag (byte-identity companion) --------------------------------------------
func _gate_off(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	if not CubeSphere.FP_FAR_SKIN_FINE:
		_ok(not baker.fine_on(), "G-FSF-OFF: FP_FAR_SKIN_FINE off ⇒ baker.fine_on() false (the orbit fine path is never armed)")
		_ok(baker.fine_working_bytes() == 0, "G-FSF-OFF: fine_working_bytes() == 0 off the flag (zero added bytes)")
		_ok(not baker.fine_orbit_active(true, FA.R_BLOCKS + 9000.0),
			"G-FSF-OFF: fine_orbit_active(off-surface, far-orbit) false off the flag — the shipped close-up promotion is untouched")
	else:
		# Flags on but this baker structurally requires close-up: fine_on() ⇔ close-up on. Assert the requires-relationship.
		_ok(baker.fine_on() == CubeSphere.FP_FACET_TEX_CLOSEUP,
			"G-FSF-OFF: fine_on() (%s) tracks FP_FACET_TEX_CLOSEUP (%s) — FP_FAR_SKIN_FINE requires the close-up pool"
			% [str(baker.fine_on()), str(CubeSphere.FP_FACET_TEX_CLOSEUP)])

# --- G-FSF-ORBIT: at far-orbit the fine disc promotes, bounded to the cap + within the sub-camera disc ------------
func _gate_orbit(fid: int) -> void:
	var axis := _centre_dir(fid)
	var r := FA.R_BLOCKS
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.prewarm(PackedInt32Array([fid]))          # base floor so the disc has a coverage floor while it bakes
	var cam_dist := r + 9000.0                        # far-orbit: cam_dist ≫ CLOSEUP_FAR ⇒ the fine orbit path drives
	_ok(baker.fine_orbit_active(true, cam_dist), "G-FSF-ORBIT: fine_orbit_active(off-surface, cam_dist=%.0f > CLOSEUP_FAR %.0f) true" % [cam_dist, CubeSphere.CLOSEUP_FAR])
	# Pump until residency settles (big budget so the disc's row-sliced bakes resolve within a few frames).
	var last := -1
	var stable := 0
	for _i in range(120):
		baker.update([axis.x, axis.y, axis.z], true, 100.0, fid, cam_dist)
		var res := baker.closeup_resident_count()
		if res == last:
			stable += 1
			if stable >= 4 and res > 0:
				break
		else:
			stable = 0
			last = res
	var resident := baker.closeup_resident_count()
	_ok(resident > 0 and resident <= CubeSphere.FAR_SKIN_FINE_MAX,
		"G-FSF-ORBIT: orbit fine residency = %d — promoted (>0) and BOUNDED ≤ FAR_SKIN_FINE_MAX %d" % [resident, CubeSphere.FAR_SKIN_FINE_MAX])
	# Every resident lies inside the sub-camera disc (within FAR_SKIN_FINE_CAP_DEG of the axis).
	var cos_cap := cos(deg_to_rad(CubeSphere.FAR_SKIN_FINE_CAP_DEG))
	var all_in := true
	var slots := baker.closeup_slots()
	for f in slots.keys():
		var cd := _centre_dir(int(f))
		if cd.dot(axis) < cos_cap - 0.0001:
			all_in = false
	_ok(all_in, "G-FSF-ORBIT: every orbit fine facet lies within FAR_SKIN_FINE_CAP_DEG %.1f° of the sub-camera axis (the disc the player looks at)" % CubeSphere.FAR_SKIN_FINE_CAP_DEG)
	_ok(baker.fine_working_bytes() <= CubeSphere.FAR_SKIN_FINE_BYTES_MAX,
		"G-FSF-ORBIT: fine_working_bytes() = %.3f MB ≤ ceiling %.2f MB (the cap binds on REAL close-up layer bytes)"
		% [float(baker.fine_working_bytes()) / 1048576.0, float(CubeSphere.FAR_SKIN_FINE_BYTES_MAX) / 1048576.0])
	print("    [G-FSF-ORBIT] far-orbit fine residency %d/%d, working-set %.3f MB, peak %.3f MB"
		% [resident, CubeSphere.FAR_SKIN_FINE_MAX, float(baker.fine_working_bytes()) / 1048576.0, float(baker.fine_peak_working_bytes()) / 1048576.0])

# --- G-FSF-SURFACE: the fine promotion is ORBIT-ONLY (empty on the surface / below CLOSEUP_FAR) -------------------
func _gate_surface(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	var r := FA.R_BLOCKS
	_ok(not baker.fine_orbit_active(false, r + 9000.0),
		"G-FSF-SURFACE: fine_orbit_active is false ON THE SURFACE (off-surface=false) even at far cam_dist — the fine disc is orbit-only")
	_ok(not baker.fine_orbit_active(true, r + 1000.0) and r + 1000.0 <= r + CubeSphere.CLOSEUP_FAR + 1.0,
		"G-FSF-SURFACE: fine_orbit_active is false BELOW CLOSEUP_FAR (cam_dist %.0f ≤ %.0f) — the shipped near close-up path runs there"
		% [r + 1000.0, r + CubeSphere.CLOSEUP_FAR])

## Facet `fid`'s centre DIRECTION (unit) — the average of its 4 planar corners, normalized (mirrors FacetTexBaker's
## _ensure_centre_pack / the sub-camera axis of a camera looking straight at this facet).
func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(float(c[0]), float(c[1]), float(c[2]))
	return s.normalized()
