extends SceneTree
## COSMOS-FRAME-ORIENTATION §6.2 / §7 step 1 — exhaustive unit gate for ShapeCodec.rotate_modifier.
## Pure, no curved mode / no chart needed (FLAT_WORLD irrelevant — this is modifier algebra).
## Asserts the D4 group law over EVERY direction-carrying modifier payload:
##   rotate(m,0) == m ; rotate⁴ == id ; rotate(a)∘rotate(b) == rotate(a+b) ; isotropic = fixed points.

var _pass := 0
var _fail := 0

func _ck(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", msg)

func _all_payloads() -> Array:
	var out: Array = []
	out.append(0)                                   # full cube (isotropic)
	# corner-height family: every c00,c10,c11,c01 in {0,1,2}, both anchors
	for a in [ShapeCodec.ANCHOR_BOTTOM, ShapeCodec.ANCHOR_TOP]:
		for c0 in 3:
			for c1 in 3:
				for c2 in 3:
					for c3 in 3:
						out.append(ShapeCodec.make_modifier(c0, c1, c2, c3, a))
	# FAM LAYER (snow) levels 1..9 (isotropic)
	for lv in range(1, 10):
		out.append(CellCodec.make_layer(lv))
	# FAM SLOPE: a spread of signed delta tuples (−3..+4), incl. asymmetric directional ones
	for d0 in [-2, -1, 0, 1, 2, 3]:
		for d1 in [-1, 0, 2]:
			for d2 in [-1, 1, 3]:
				for d3 in [0, 1, -2]:
					out.append(CellCodec.make_slope(d0, d1, d2, d3))
	return out

func _init() -> void:
	print("=== verify_shape_rot (ShapeCodec.rotate_modifier D4 group law) ===")
	var payloads := _all_payloads()
	print("payloads: ", payloads.size())

	# (1) rotate(m, 0) == m and rotate⁴ == id
	for m: int in payloads:
		_ck(ShapeCodec.rotate_modifier(m, 0) == m, "rotate(%d,0) != m" % m)
		var r := m
		for _k in 4:
			r = ShapeCodec.rotate_modifier(r, 1)
		_ck(r == m, "rotate⁴(%d) = %d != m" % [m, r])
		# 180 == two 90s ; 270 == three 90s
		_ck(ShapeCodec.rotate_modifier(m, 2) == ShapeCodec.rotate_modifier(ShapeCodec.rotate_modifier(m, 1), 1), "180 != 90∘90 for %d" % m)
		_ck(ShapeCodec.rotate_modifier(m, 3) == ShapeCodec.rotate_modifier(ShapeCodec.rotate_modifier(ShapeCodec.rotate_modifier(m, 1), 1), 1), "270 != 90∘90∘90 for %d" % m)

	# (2) group law rotate(a)∘rotate(b) == rotate(a+b), all a,b
	for m: int in payloads:
		for a in 4:
			for b in 4:
				var lhs := ShapeCodec.rotate_modifier(ShapeCodec.rotate_modifier(m, b), a)
				var rhs := ShapeCodec.rotate_modifier(m, a + b)
				_ck(lhs == rhs, "group law fail m=%d a=%d b=%d (%d != %d)" % [m, a, b, lhs, rhs])

	# (3) isotropic fixed points: full cube + every LAYER level unchanged by any rotation
	for q in 4:
		_ck(ShapeCodec.rotate_modifier(0, q) == 0, "full cube not fixed at q=%d" % q)
		for lv in range(1, 10):
			var lm := CellCodec.make_layer(lv)
			if CellCodec.is_layer(lm):
				_ck(ShapeCodec.rotate_modifier(lm, q) == lm, "LAYER %d not fixed at q=%d" % [lv, q])

	# (4) a DIRECTIONAL shape actually MOVES under a quarter turn (not silently a no-op)
	var slope_dir := CellCodec.make_slope(2, 0, 0, 0)      # high at c00 only
	_ck(ShapeCodec.rotate_modifier(slope_dir, 1) != slope_dir, "directional slope unchanged by 90° (rotation is a no-op!)")
	var ramp_dir := ShapeCodec.make_modifier(2, 2, 0, 0, ShapeCodec.ANCHOR_BOTTOM)   # a directional wedge
	_ck(ShapeCodec.rotate_modifier(ramp_dir, 1) != ramp_dir, "directional ramp unchanged by 90°")

	print("=== rotate_modifier: %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
