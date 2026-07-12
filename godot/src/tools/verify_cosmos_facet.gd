extends SceneTree
## FP0 FacetAtlas math gate — validates the study's headline: the 8×90° cube corners DISSOLVE under faceting,
## and the dihedral ridges match the predicted mild angles. Pure math (no scene), flag-independent.

const CF := preload("res://src/cosmos/cosmos_facet.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _init() -> void:
	print("=== verify_cosmos_facet (FP0 FacetAtlas) ===")
	# corner defect dissolves (study: ~2.2° @k=8, ~0.47° @k=16) — vs the cube-sphere's 90°.
	for corner in range(8):
		var d8 := CF.corner_defect_deg(8, corner)
		_ok(d8 > 0.0 and d8 < 5.0, "corner %d defect @k=8 = %.3f° (< 5°, was 90° on cube)" % [corner, d8])
		var d16 := CF.corner_defect_deg(16, corner)
		_ok(d16 > 0.0 and d16 < 2.0, "corner %d defect @k=16 = %.3f° (< 2°)" % [corner, d16])
	print("  sample corner defect @k=8 = %.3f°, @k=16 = %.3f° (study: 2.2 / 0.47)" % [CF.corner_defect_deg(8, 0), CF.corner_defect_deg(16, 0)])
	# dihedral ridges (study: ~10° mid-face @k=8, ~5.2° @k=16).
	var dh8 := CF.sample_dihedral_deg(4, 3, 3, 8)
	var dh16 := CF.sample_dihedral_deg(4, 7, 7, 16)
	_ok(dh8 > 5.0 and dh8 < 15.0, "mid-face dihedral @k=8 = %.2f° (study ~10)" % dh8)
	_ok(dh16 > 3.0 and dh16 < 9.0, "mid-face dihedral @k=16 = %.2f° (study ~5.2)" % dh16)
	# facet geometry sanity: corners on the unit sphere × R, flat-quad interior between them.
	var c := CF.facet_corners(4, 3, 3, 8, 512.0)
	var all_on_sphere := true
	for p in c:
		if absf(p.length() - 512.0) > 0.5:
			all_on_sphere = false
	_ok(all_on_sphere, "facet corners lie on the sphere (R=512)")
	var mid := CF.facet_pos_at(4, 3, 3, 8, 0.5, 0.5, 512.0)
	_ok(mid.length() < 512.0, "flat-quad facet centre is INSIDE the sphere (chord, not arc) — |c|=%.2f < 512" % mid.length())

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
