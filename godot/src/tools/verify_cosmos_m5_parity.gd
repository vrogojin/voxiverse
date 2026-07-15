extends SceneTree
## COSMOS-M5-ADR §2.3 + COSMOS-PROJECTION-STUDY §3.3 — the UNIFORM-PARITY harness (Fable's gate for the
## WebGL2 break). The CPU mirror (verify_cosmos_m5) proved the MATH; this proves the TRANSPORT: it feeds a
## GDScript transcription of the M5 vertex GLSL the SAME packed uniform arrays the materials receive
## (CosmosTruePlace.pack_chart_table), and diffs it against place_point over the T1 probe set — home + all
## 4 strips + the wedge, across TWO chart epochs (identity M_win AND a rotated/shifted M_win). A wrong
## array index / component order / int→float sign in the pack OR the shader indexing diverges here, headless.
## Curved-only (loud-skip + exit 2 under FLAT). GATE-BLOCKING before any redeploy.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TP := preload("res://src/cosmos/cosmos_true_place.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# The window coord that maps to the TRUE cell CENTRE (f, fx, fz): invert the fold then M_win⁻¹ (works for
# any M_win — the rotated epoch too). Mirrors verify_cosmos_m5._window_for_true.
func _window_for_true(chart, f: int, fx: float, fz: float) -> Vector2:
	var n: int = chart.n
	var raw := Vector2(fx, fz)
	if f != chart.face:
		for side in 4:
			var e := CS.edge_remap(chart.face, side, n)
			if int(e["b"]) == f:
				var m: Array = e["m"]
				var t: Array = e["t"]
				var a := int(m[0]); var b := int(m[1]); var c := int(m[2]); var d := int(m[3])
				var px := fx - float(t[0]); var pz := fz - float(t[1])
				raw = Vector2(float(d) * px - float(b) * pz, -float(c) * px + float(a) * pz)   # M_s⁻¹ (det +1)
				break
	var pi := raw.x - float(chart.i_org)
	var pj := raw.y - float(chart.j_org)
	# M_win⁻¹ (det +1): [[d,-b],[-c,a]]
	var det := float(chart.mw_a * chart.mw_d - chart.mw_b * chart.mw_c)
	var wx := (float(chart.mw_d) * pi - float(chart.mw_b) * pj) / det
	var wz := (-float(chart.mw_c) * pi + float(chart.mw_a) * pj) / det
	return Vector2(wx, wz)

## The EXACT GDScript transcription of the M5 NEAR vertex GLSL (_M5_CLASSIFY + _M5_VERTEX_NEAR), reading
## ONLY from the packed uniform dict `pk` + the camera frame — the same data the GPU sees. Returns the
## camera-relative render offset (== place_point). Any packing/indexing bug makes this differ from place_point.
func _glsl_place(pk: Dictionary, frame: Dictionary, radius: float, w: Vector3) -> Vector3:
	var cam: Vector3 = frame["w_cam"]
	var dcam: Vector3 = frame["d_cam"]
	var ycam: float = float(frame["y_cam"])
	var mt: Basis = frame["mt"]
	var org: Vector2 = pk["chart_org"]
	var mwin: Vector4 = pk["chart_mwin"]
	var nc: float = float(pk["chart_ncells"])
	var cm: Array = pk["chart_m"]; var ct: Array = pk["chart_t"]
	var an: Array = pk["chart_axn"]; var au: Array = pk["chart_axu"]; var av: Array = pk["chart_axv"]
	var ident := w - cam
	var s := smoothstep(16.0, 104.0, Vector2(w.x - cam.x, w.z - cam.z).length())
	var p := org + Vector2(mwin.x * w.x + mwin.y * w.z, mwin.z * w.x + mwin.w * w.z)
	var oi := p.x < 0.0 or p.x >= nc
	var oj := p.y < 0.0 or p.y >= nc
	var idx := 0
	if oi and oj: idx = 5
	elif not oi and not oj: idx = 0
	elif p.x >= nc: idx = 1
	elif p.x < 0.0: idx = 2
	elif p.y >= nc: idx = 3
	else: idx = 4
	var ai := 0 if idx == 5 else idx
	var mm: Vector4 = cm[ai]; var tt: Vector2 = ct[ai]
	var fc := Vector2(mm.x * p.x + mm.y * p.y + tt.x, mm.z * p.x + mm.w * p.y + tt.y)
	var nn: Vector3 = an[ai]; var uu: Vector3 = au[ai]; var vv: Vector3 = av[ai]
	if idx == 5:
		return ident * (1.0 - s)
	var a := 2.0 * fc.x / nc - 1.0
	var b := 2.0 * fc.y / nc - 1.0
	var dd := (nn + uu * tan(a * (PI / 4.0)) + vv * tan(b * (PI / 4.0))).normalized()
	var rel := dd * radius - dcam * radius + dd * w.y - dcam * ycam
	return ident.lerp(mt * rel, s)

func _run_epoch(chart, cam: Vector3, label: String) -> void:
	var frame := TP.camera_frame(chart, cam)
	var pk := TP.pack_chart_table(chart)
	var rr := float(chart.radius)
	var worst := 0.0
	var hit := {}                                   # idx → count (coverage)
	# home + the 4 strips (true cells, fold-inverted so each lands in a known chart)
	var neigh := {chart.face: true}
	for side in 4:
		neigh[int(CS.edge_remap(chart.face, side, chart.n)["b"])] = true
	for f in neigh.keys():
		for cell: Vector2i in [Vector2i(250, 250), Vector2i(1100, 600), Vector2i(60, 900)]:
			var wc := _window_for_true(chart, int(f), float(cell.x) + 0.5, float(cell.y) + 0.5)
			var w := Vector3(wc.x, cam.y + 2.0, wc.y)
			var g := _glsl_place(pk, frame, rr, w)
			var e := TP.place_point(chart, w, frame)
			worst = maxf(worst, (g - e).length())
			var idx := _classify(pk, w)
			hit[idx] = int(hit.get(idx, 0)) + 1
	# the wedge (double-out): a window point whose raw p is out on BOTH axes
	for wq: Vector3 in _wedge_probes(chart, cam):
		var g := _glsl_place(pk, frame, rr, wq)
		var e := TP.place_point(chart, wq, frame)
		worst = maxf(worst, (g - e).length())
		var idx := _classify(pk, wq)
		hit[idx] = int(hit.get(idx, 0)) + 1
	var covered := hit.has(0) and hit.has(1) and hit.has(2) and hit.has(3) and hit.has(4) and hit.has(5)
	_ok(worst < 1e-3, "%s parity: transcribed-GLSL == place_point over home+4 strips+wedge (worst %.8f blk)" % [label, worst])
	_ok(covered, "%s coverage: all 6 chart classes exercised (home/E/W/N/S/wedge) — hits %s" % [label, str(hit)])

func _classify(pk: Dictionary, w: Vector3) -> int:
	var org: Vector2 = pk["chart_org"]; var mwin: Vector4 = pk["chart_mwin"]; var nc: float = float(pk["chart_ncells"])
	var p := org + Vector2(mwin.x * w.x + mwin.y * w.z, mwin.z * w.x + mwin.w * w.z)
	var oi := p.x < 0.0 or p.x >= nc
	var oj := p.y < 0.0 or p.y >= nc
	if oi and oj: return 5
	if not oi and not oj: return 0
	if p.x >= nc: return 1
	if p.x < 0.0: return 2
	if p.y >= nc: return 3
	return 4

# Window points landing in the double-out corner wedge (raw p out on both axes), for any M_win: invert
# M_win on a raw target that is below-both-zero near the origin corner.
func _wedge_probes(chart, cam: Vector3) -> Array:
	var out: Array = []
	for raw: Vector2 in [Vector2(-5, -5), Vector2(-40, -12), Vector2(-3, -80)]:
		var pi := raw.x - float(chart.i_org)
		var pj := raw.y - float(chart.j_org)
		var det := float(chart.mw_a * chart.mw_d - chart.mw_b * chart.mw_c)
		var wx := (float(chart.mw_d) * pi - float(chart.mw_b) * pj) / det
		var wz := (-float(chart.mw_c) * pi + float(chart.mw_a) * pj) / det
		out.append(Vector3(wx, cam.y + 1.0, wz))
	return out

func _init() -> void:
	print("=== verify_cosmos_m5_parity (uniform transport) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — M5a is curved-only; needs FLAT_WORLD=false. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)
		return
	# Epoch A: fresh chart, identity M_win, corner origin (all strips + wedge reachable via the fold).
	var ca: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)
	_run_epoch(ca, Vector3(28.0, 4.0, 22.0), "epochA(id)")
	# Epoch B: a rotated + shifted M_win (a genuine post-flip/reanchor state) — catches M_win/org packing
	# bugs invisible at identity. 90° D4 rotation [[0,-1],[1,0]] (det +1) + a non-zero origin.
	var cb: CHART = CHART.new(CS.HOME_BODY, 4, 137, -84)
	cb.mw_a = 0; cb.mw_b = -1; cb.mw_c = 1; cb.mw_d = 0
	_run_epoch(cb, Vector3(-11.0, 5.0, 40.0), "epochB(rot)")
	# Epoch C: a DIFFERENT home face (0) — exercises the per-face axis packing for another face's table.
	var cc: CHART = CHART.new(CS.HOME_BODY, 0, 0, 0)
	_run_epoch(cc, Vector3(19.0, 4.0, 33.0), "epochC(face0)")
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
