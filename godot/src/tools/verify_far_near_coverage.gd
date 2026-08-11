extends SceneTree
## FP_ORBIT_RELIEF_SURFACE_HIDE gate (docs/COSMOS-FAR-NEAR-COVERAGE-DESIGN.md, task #110).
##
## The far-over-near mountain protrusion: on a steep summit the FacetOrbitRelief (G3, FP_ORBIT_RELIEF) mesh —
## FROZEN + VISIBLE + UN-SUNK on-surface (its step() suspends recompute/commit below OFFSURFACE_Y but leaves the
## last committed mesh drawn) — rides ABOVE the fine near block tops at its coarse 13-block DEM pitch. The fix
## (FP_ORBIT_RELIEF_SURFACE_HIDE) toggles the ONE MeshInstance's `.visible` to `ring.shell_offsurface()` in
## step() (hidden on-surface, shown off-surface) — render-only, frozen tiles/arena/bytes untouched. The #107
## near-fill is EXONERATED (measured strictly below the fine surface) and must NOT be touched.
##
## Gates (self-describing — the compiled flags decide which assertions are meaningful, mirroring
## verify_orbit_relief.gd):
##   G-FNC-OFF  — FP_ORBIT_RELIEF_SURFACE_HIDE off: step() NEVER writes `_mi.visible` across a simulated
##                on-surface → off-surface cycle (byte-off: the shipped visibility is untouched). Runs its real
##                assertion only when the flag is OFF; skips (trivially passes) when ON.
##   G-FNC-HIDE — FP_ORBIT_RELIEF_SURFACE_HIDE on: driving the ring latch on-surface → off-surface → on-surface,
##                `_mi.visible` tracks `shell_offsurface()` EXACTLY (false on-surface, true off-surface), and no
##                bytes are freed — `_tiles.size()` / the arena stay invariant across the hide (frozen warmth
##                kept). Runs its real assertion only when the flag is ON; skips when OFF.
##   G-FNC-LAW  — the protrusion pin (flag-independent, law-level, reproduces probe_orelief_protrude.gd): on facet
##                578's repro window, (a) the V2 near-fill surface (52-cell chord − V2_NEARFILL_SINK) is STRICTLY
##                below the fine analytic surface everywhere (worst < 0 — proves #107's near-fill is not the
##                protruder, so a future change that lifts it above near blocks fails loudly); (b) the UN-SUNK
##                32-cell G3 chord field is above the fine surface over > 25 % of the window (proves the G3
##                discriminator stays reproducible, so re-exposing an un-sunk on-surface G3 fails loudly).
##
## RUN (needs FACETED sed-toggled true for G-FNC-LAW's profile branch; FP_ORBIT_RELIEF + FP_GLOBAL_RELIEF_DATA
## for the instance fixtures; toggle FP_ORBIT_RELIEF_SURFACE_HIDE for the OFF/ON A/B):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_far_near_coverage.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FOR_ := preload("res://src/world/facet_orbit_relief.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-4

# --- G-FNC-LAW window (probe_orelief_protrude.gd's exact repro spot on facet 578) -------------------------------------
const LAW_FID := 578
const LAW_WIN_X := 13034
const LAW_WIN_Z := 8153
const LAW_WIN_R := 72

func _initialize() -> void:
	print("=== verify_far_near_coverage (task #110 — FP_ORBIT_RELIEF_SURFACE_HIDE) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()

	_gate_off()
	_gate_hide()
	_gate_law()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Off-surface fixture poke (mirrors verify_orbit_relief.gd's `_force_offsurface`): a bare FacetFarRing defaults
## ON-surface (`_cam_set=false` ⇒ `shell_offsurface()==false`); set the two private fields it reads to flip it.
func _force_offsurface(ring: FacetFarRing) -> void:
	ring._cam_set = true
	ring._emit_floored_last = false

func _force_onsurface(ring: FacetFarRing) -> void:
	ring._cam_set = false

## Build a live FacetOrbitRelief instance whose step() reaches the visibility line (needs `_relief_data != null`
## and `_sn > 0`, both set by setup_instance). No bake needed — the reap loop is empty, we assert only visibility.
func _make_instance(ring: FacetFarRing, fid: int) -> FacetOrbitRelief:
	var rd := GlobalReliefData.new()
	rd.setup()
	ring._active_fid = fid
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)
	return relief

# --- G-FNC-OFF: flag off ⇒ step() never writes `_mi.visible` (byte-off, shipped visibility untouched) ----------------
func _gate_off() -> void:
	if CubeSphere.FP_ORBIT_RELIEF_SURFACE_HIDE:
		_ok(true, "G-FNC-OFF: skipped this run (flag currently ON — G-FNC-HIDE covers behaviour)")
		return
	var ring := FacetFarRing.new()
	var relief := _make_instance(ring, 12)
	_ok(relief._mi != null, "G-FNC-OFF: fixture — the instance owns its MeshInstance (_mi)")
	# Pre-set a SENTINEL the on-surface hide path would OVERWRITE to false if the flag were live. With the flag
	# off, step() must leave it exactly as set across BOTH an on-surface and an off-surface step.
	relief._mi.visible = true
	_ok(not ring.shell_offsurface(), "G-FNC-OFF: fixture — a bare ring is ON-surface")
	relief.step()   # on-surface, flag off: must NOT touch _mi.visible
	_ok(relief._mi.visible == true, "G-FNC-OFF: on-surface step() with the flag off never writes _mi.visible (sentinel intact)")
	relief._mi.visible = true
	_force_offsurface(ring)
	relief.step()   # off-surface, flag off: must NOT touch _mi.visible either
	_ok(relief._mi.visible == true, "G-FNC-OFF: off-surface step() with the flag off never writes _mi.visible (sentinel intact) — shipped visibility verbatim")
	ring.free()

# --- G-FNC-HIDE: flag on ⇒ `_mi.visible` tracks shell_offsurface() exactly; frozen tiles/bytes retained -------------
func _gate_hide() -> void:
	if not CubeSphere.FP_ORBIT_RELIEF_SURFACE_HIDE:
		_ok(true, "G-FNC-HIDE: skipped this run (flag currently OFF — G-FNC-OFF covers byte-off)")
		return
	var ring := FacetFarRing.new()
	var relief := _make_instance(ring, 12)
	_ok(relief._mi != null, "G-FNC-HIDE: fixture — the instance owns its MeshInstance (_mi)")

	# Seed a resident tile so we can prove the hide is RENDER-ONLY (no bytes freed): fake one committed tile.
	relief._tiles[999] = {"marker": true}
	var tiles_before := relief._tiles.size()

	# Phase 1: on-surface — hidden.
	_force_onsurface(ring)
	_ok(not ring.shell_offsurface(), "G-FNC-HIDE: fixture — ring is ON-surface for phase 1")
	relief._mi.visible = true   # start VISIBLE so a false result proves step() actively hid it
	relief.step()
	_ok(relief._mi.visible == false, "G-FNC-HIDE: on-surface ⇒ step() sets _mi.visible = false (hidden — matches shell_offsurface()==false)")
	_ok(relief._tiles.size() == tiles_before, "G-FNC-HIDE: on-surface hide freed NO tiles — frozen warmth kept (_tiles invariant)")

	# Phase 2: off-surface — shown.
	_force_offsurface(ring)
	_ok(ring.shell_offsurface(), "G-FNC-HIDE: fixture — ring is OFF-surface for phase 2")
	relief._mi.visible = false   # start HIDDEN so a true result proves step() actively showed it
	relief.step()
	_ok(relief._mi.visible == true, "G-FNC-HIDE: off-surface ⇒ step() sets _mi.visible = true (shown — matches shell_offsurface()==true)")

	# Phase 3: back on-surface — hidden again (the latch is not one-way).
	_force_onsurface(ring)
	relief._mi.visible = true
	relief.step()
	_ok(relief._mi.visible == false, "G-FNC-HIDE: returning on-surface re-hides _mi (visible tracks the latch in BOTH directions)")
	_ok(relief._tiles.has(999) and relief._tiles.size() >= 1, "G-FNC-HIDE: the seeded resident tile is still present after the full hide/show/hide cycle — 0 bytes freed")

	ring.free()

# --- G-FNC-LAW: the protrusion pin (reproduces probe_orelief_protrude.gd, law-equal to the live bakes) --------------
# FarDensity.node_at ≡ the native bake_smooth_tile height law (probe_orelief_protrude.gd:34 / :76). So the
# 52-cell node grid − V2_NEARFILL_SINK reproduces the #107 near-fill tile's vertex radii (FacetSmoothV2.build_tile
# sinks every node by `sink`, facet_smooth_v2.gd:92-93), and the 32-cell UN-SUNK node grid reproduces G3's
# frozen on-surface chords (facet_orbit_relief.gd interior nodes accepted at face value). Compared against the
# fine analytic surface (TerrainConfig.profile_at_dir at ~1-block pitch) over facet 578's repro window.
func _gate_law() -> void:
	var r_datum := FacetAtlas.r_of(LAW_FID)
	var cd := FacetAtlas.facet_corner_dirs(LAW_FID)
	var g3 := _node_grid(cd, r_datum, GlobalReliefData.CELLS)         # 32 cells (~13-block pitch) — G3, un-sunk
	var v2 := _node_grid(cd, r_datum, CubeSphere.V2_CELLS)            # 52 cells (~8-block pitch) — V2 near-fill
	var sink := CubeSphere.V2_NEARFILL_SINK                          # 6.0 blocks radial drop

	# window centre (s,t) via corner-lattice affine inversion (probe_orelief_protrude.gd:22-32)
	var l00 := _corner_lat(cd, r_datum, 0)
	var l10 := _corner_lat(cd, r_datum, 1)
	var l01 := _corner_lat(cd, r_datum, 3)
	var sx := l10 - l00
	var tz := l01 - l00
	var det := sx.x * tz.y - sx.y * tz.x
	var p := Vector2(float(LAW_WIN_X) + 0.5, float(LAW_WIN_Z) + 0.5) - l00
	var c_s := clampf((p.x * tz.y - p.y * tz.x) / det, 0.0, 1.0)
	var c_t := clampf((sx.x * p.y - sx.y * p.x) / det, 0.0, 1.0)

	var span := float(LAW_WIN_R) / 417.0
	var nn := LAW_WIN_R * 2
	var g3_over := 0
	var g3_worst := -1e9
	var v2_worst := -1e9
	var total := 0
	for j in range(nn + 1):
		var t := clampf(c_t - span + 2.0 * span * float(j) / float(nn), 0.0, 1.0)
		for i in range(nn + 1):
			var s := clampf(c_s - span + 2.0 * span * float(i) / float(nn), 0.0, 1.0)
			var nd := FarDensity.node_dir(cd, s, t)
			var prof := TerrainConfig.profile_at_dir(nd.x, nd.y, nd.z, r_datum)
			var fine := r_datum + maxf(0.0, float(int(prof.x) - TerrainConfig.SEA_LEVEL))
			var d3 := _interp_r(g3, GlobalReliefData.CELLS, s, t) - fine            # G3: UN-SUNK
			var d2 := (_interp_r(v2, CubeSphere.V2_CELLS, s, t) - sink) - fine      # V2 near-fill: sunk 6
			total += 1
			if d3 > 0.0: g3_over += 1
			g3_worst = maxf(g3_worst, d3)
			v2_worst = maxf(v2_worst, d2)
	var g3_frac := 100.0 * float(g3_over) / float(total)
	# (a) V2 near-fill is EXONERATED — strictly below the fine surface everywhere (measured worst −4.76).
	_ok(v2_worst < 0.0, "G-FNC-LAW(a): V2 near-fill (52-cell chord − sink %.0f) is STRICTLY below the fine surface over the whole window (worst %+.2f blk < 0) — #107's near-fill is not the protruder" % [sink, v2_worst])
	# (b) G3 un-sunk chords ARE above the fine surface over a broad field — the reproducible protrusion discriminator.
	_ok(g3_frac > 25.0, "G-FNC-LAW(b): the UN-SUNK 32-cell G3 chord field is above the fine surface over %.1f%% of the window (> 25%%, measured 35.4%%; worst %+.2f blk) — G3 is the protruder" % [g3_frac, g3_worst])
	print("  [G-FNC-LAW] window %d samples: G3 over-fine %.1f%% (worst %+.2f), V2 near-fill worst %+.2f" % [total, g3_frac, g3_worst, v2_worst])

# --- probe_orelief_protrude.gd math (node grid / corner lattice / triangle interp), reproduced ----------------------
func _node_grid(cd: PackedFloat64Array, r_datum: float, cells: int) -> PackedFloat64Array:
	var stride := cells + 1
	var out := PackedFloat64Array()
	out.resize(stride * stride)
	for gj in range(stride):
		for gi in range(stride):
			var nd: Dictionary = FarDensity.node_at(cd, r_datum, float(gi) / float(cells), float(gj) / float(cells))
			out[gj * stride + gi] = r_datum + float(nd["relief"])
	return out

func _corner_lat(cd: PackedFloat64Array, r: float, k: int) -> Vector2:
	var d := Vector3(cd[k * 3], cd[k * 3 + 1], cd[k * 3 + 2]).normalized()
	var wp := d * r
	var lat: Array = FacetAtlas.world_to_lattice64(LAW_FID, wp.x, wp.y, wp.z)
	return Vector2(float(lat[0]), float(lat[2]))

func _interp_r(node_r: PackedFloat64Array, cells: int, s: float, t: float) -> float:
	var stride := cells + 1
	var fs_all := s * float(cells)
	var ft_all := t * float(cells)
	var gi := clampi(int(floor(fs_all)), 0, cells - 1)
	var gj := clampi(int(floor(ft_all)), 0, cells - 1)
	var fs := fs_all - float(gi)
	var ft := ft_all - float(gj)
	var r00 := node_r[gj * stride + gi]
	var r10 := node_r[gj * stride + gi + 1]
	var r01 := node_r[(gj + 1) * stride + gi]
	var r11 := node_r[(gj + 1) * stride + gi + 1]
	# same diagonal split as G3/V2 (facet_orbit_relief.gd:271-272)
	if fs >= ft:
		return r00 + (r10 - r00) * fs + (r11 - r10) * ft
	return r00 + (r01 - r00) * ft + (r11 - r01) * fs
