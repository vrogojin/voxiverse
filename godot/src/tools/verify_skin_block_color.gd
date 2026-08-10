extends SceneTree
## FP_SKIN_BLOCK_COLOR gate (docs/COSMOS-SKIN-BLOCK-COLOR-DESIGN.md).
##
## Proves FarPalette.skin_color / skin_color_at (the shared law facet_far_ring.gd's 7 sites + _weld_node,
## facet_smooth_v2.gd's build_tile, and facet_block_lod_ring.gd's _build_facet_arrays all route through) is
## byte-off by default and, when driven ON, resolves to the ACTUAL top block's colour — not a flat biome tint —
## and agrees with the already-shipped FP_SKIN_BLOCK_EXACT fine-map law. `on` is an explicit param on both
## functions (default = the compiled CubeSphere.FP_SKIN_BLOCK_COLOR const) so this gate drives BOTH branches in
## one run without sed-toggling, the SAME idiom FarPalette._biome_tints(unified: bool) already established for
## verify_far_color_unified.gd.
##
## Gates:
##   G-SBC-OFF              — FP_SKIN_BLOCK_COLOR defaults false; skin_color/skin_color_at(on=false) ==
##                             FarPalette.color_for byte-exact, over ≥200 columns spanning every biome + the
##                             sea/snow/dry regimes.
##   G-SBC-ON-DISCRIMINATES — a mixed TAIGA tile (podzol/grass hash speckle) yields exactly ONE colour with
##                             on=false (proving the baseline really is flat) and ≥2 distinct frozen_colors()
##                             indices with on=true (proving top_block_id's per-column classification actually
##                             reaches the vertex colour, not just computed and discarded).
##   G-SBC-PARITY            — skin_color_at(on=true) resolves to the SAME frozen_colors() index as the
##                             already-shipped fine-map law (far_color_index_of_block(top_block_id(...)),
##                             facet_tex_baker.gd's FP_SKIN_BLOCK_EXACT branch) for the same column — exact
##                             index match, not a tolerance band (both terminate in the identical call).
##   G-SBC-WORKER-SAFE       — static source check: none of facet_far_ring.gd / facet_smooth_v2.gd /
##                             facet_block_lod_ring.gd call FarPalette._top_color( or BlockTextures.mean_color_of(
##                             — the ON path only ever resolves through the quantised, worker-safe LUT.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_skin_block_color.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const FP := preload("res://src/world/far/far_palette.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_skin_block_color (COSMOS-SKIN-BLOCK-COLOR-DESIGN, FP_SKIN_BLOCK_COLOR) ===")
	TC._ensure_noise()
	TC._ensure_ids()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FP.ensure_ready()
	FP.ensure_far_index_ready()
	var fid := FA.spawn_facet()
	print("  CubeSphere.FP_SKIN_BLOCK_COLOR = %s (compile-time; gate drives both branches via the `on` param)" % str(CubeSphere.FP_SKIN_BLOCK_COLOR))
	print("  fixture fid=%d" % fid)

	_ok(not CubeSphere.FP_SKIN_BLOCK_COLOR, "G-SBC-OFF: FP_SKIN_BLOCK_COLOR defaults false")
	_gate_off(fid)
	_gate_on_discriminates(fid)
	_gate_parity(fid)
	_gate_worker_safe()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-SBC-OFF: on=false reproduces FarPalette.color_for byte-exact ----------
# Biomes exercised (terrain_config.gd:287-304): every Earth biome id, plus dry/snow/sea/lava regimes via g,t.
const _BIOMES: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]   # B_OCEAN..B_JUNGLE
func _gate_off(fid: int) -> void:
	print("  --- G-SBC-OFF: skin_color/skin_color_at(on=false) byte-exact to color_for ---")
	var n := 0
	var all_ok := true
	for biome in _BIOMES:
		for gi in range(-4, 6):                 # spans below/at/above SEA_LEVEL (=0)
			var g := gi * 20
			for ti in range(-3, 4):              # spans frozen .. molten
				var t := float(ti) * 0.3
				var wx := 100.0 + float(g) * 3.0
				var wy := 50.0 - float(gi)
				var wz := 200.0 + float(ti) * 7.0
				var want := FP.color_for(g, biome, t, g < TC.SEA_LEVEL)
				var got_world := FP.skin_color(fid, wx, wy, wz, g, biome, t, false)
				var got_lattice := FP.skin_color_at(fid, int(wx), int(wz), g, biome, t, false)
				if got_world != want or got_lattice != want:
					all_ok = false
				n += 1
	_ok(n >= 200, "G-SBC-OFF: sampled >=200 columns (got %d)" % n)
	_ok(all_ok, "G-SBC-OFF: every sampled column's on=false colour == FarPalette.color_for exactly")

# ---------- G-SBC-ON-DISCRIMINATES: a mixed taiga tile is flat OFF, varied ON ----------
func _gate_on_discriminates(fid: int) -> void:
	print("  --- G-SBC-ON-DISCRIMINATES: taiga podzol/grass speckle flat OFF, varied ON ---")
	var g := 40                      # dry land, well above SEA_LEVEL
	var t := 0.5                     # warm — surface_temperature(40, 0.5) > 0, no snow-cap override
	var off_colours := {}
	var on_indices := {}
	for x in range(0, 64):
		for z in range(0, 64):
			var c_off := FP.skin_color_at(fid, x, z, g, TC.B_TAIGA, t, false)
			off_colours[c_off] = true
			var c_on := FP.skin_color_at(fid, x, z, g, TC.B_TAIGA, t, true)
			on_indices[FP.far_color_index(c_on)] = true
	_ok(off_colours.size() == 1, "G-SBC-ON-DISCRIMINATES: on=false gives exactly ONE flat colour over the taiga tile (got %d)" % off_colours.size())
	_ok(on_indices.size() >= 2, "G-SBC-ON-DISCRIMINATES: on=true gives >=2 distinct frozen_colors indices over the taiga tile (got %d — podzol vs grass speckle)" % on_indices.size())

# ---------- G-SBC-PARITY: on=true agrees with the shipped FP_SKIN_BLOCK_EXACT fine-map law ----------
func _gate_parity(fid: int) -> void:
	print("  --- G-SBC-PARITY: skin_color_at(on=true) == fine-map law's far_color_index_of_block(top_block_id) ----")
	var n := 0
	var all_ok := true
	for biome in _BIOMES:
		for gi in range(-2, 4):
			var g := gi * 15
			for ti in range(-2, 3):
				var t := float(ti) * 0.35
				for x in [0, 3, 17, 64]:
					for z in [1, 9, 40]:
						var want_idx := FP.far_color_index_of_block(TC.top_block_id(g, biome, t, x, z))
						var got := FP.skin_color_at(fid, x, z, g, biome, t, true)
						var got_idx := FP.far_color_index(got)
						if got_idx != want_idx:
							all_ok = false
						n += 1
	_ok(n >= 200, "G-SBC-PARITY: sampled >=200 columns (got %d)" % n)
	_ok(all_ok, "G-SBC-PARITY: every sampled column's on=true index == the shipped fine-map law's index")

# ---------- G-SBC-WORKER-SAFE: the ON path never touches the texture-loading colour source ----------
const _WORKER_FILES := [
	"res://src/world/facet_far_ring.gd",
	"res://src/world/facet_smooth_v2.gd",
	"res://src/world/facet_block_lod_ring.gd",
]
func _gate_worker_safe() -> void:
	print("  --- G-SBC-WORKER-SAFE: no _top_color(/mean_color_of( in the WorkerThreadPool-built consumers ---")
	for path in _WORKER_FILES:
		var f := FileAccess.open(path, FileAccess.READ)
		_ok(f != null, "G-SBC-WORKER-SAFE: opened %s" % path)
		if f == null:
			continue
		var text := f.get_as_text()
		var has_top_color := text.find("_top_color(") != -1
		var has_mean_color := text.find("mean_color_of(") != -1
		_ok(not has_top_color, "G-SBC-WORKER-SAFE: %s does not call FarPalette._top_color(" % path)
		_ok(not has_mean_color, "G-SBC-WORKER-SAFE: %s does not call BlockTextures.mean_color_of(" % path)
