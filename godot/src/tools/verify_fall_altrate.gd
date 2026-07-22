extends SceneTree
## COSMOS-PERF FALL-ALTRATE gate — G-FALL-ALTRATE (flags FP_FALL_CAMFAR_HOLD / FP_FALL_ATMO_THROTTLE /
## FP_FALL_RING_HOLD, shared core FallThrottle). Proves the descent-rate throttle contract on the PURE decision
## core (FallThrottle.should_reapply / radial_speed / is_fast), which the three consumers (player camera planes,
## CosmosSky recompute, far-ring scaled placement) all route through:
##
##   1. BYTE-OFF: flag off ⇒ should_reapply == true EVERY frame ⇒ the consumer writes exactly as shipped
##      (the full byte-identity is verify_feature FLAT 6042/0 with the three flags at their false default).
##   2. EXACT CONVERGENCE: vertical speed ≤ threshold ⇒ should_reapply == true EVERY frame ⇒ a slow / steady /
##      at-rest state re-applies the exact ramped value (the held value equals the exact value the instant the
##      descent slows — no permanent offset).
##   3. BOUNDED + RATE/FPS-INDEPENDENT: during a FAST descent the re-apply COUNT over a fixed wall-time window is
##      ≈ window/FALL_THROTTLE_MS, INDEPENDENT of the descent rate AND the frame rate — the "per-frame work no
##      longer scales with |dAlt/dt|" property. Contrast: flag off re-applies once PER FRAME (scales with fps).
##
## RUN (no flags need toggling — the gate drives the pure core directly; the three flags stay false = byte-off):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_fall_altrate.gd
## Exits 0 all-pass / 1 on any failure.

const FT := preload("res://src/cosmos/fall_throttle.gd")
const CS := preload("res://src/cosmos/cube_sphere.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Simulate a descent for `window_ms` at `fps` frames/s with radial speed `vspeed`, driving should_reapply(flag_on)
## once per frame with the wall-ms since the last re-apply. Returns [reapply_count, frame_count]. Deterministic.
func _sim(flag_on: bool, vspeed: float, fps: float, window_ms: int) -> Array:
	var dt_ms := int(round(1000.0 / fps))
	var now := 0
	var last_apply := -1000000            # far in the past ⇒ the first frame always applies
	var reapplies := 0
	var frames := 0
	while now <= window_ms:
		var ms_since := now - last_apply
		if FT.should_reapply(flag_on, vspeed, ms_since):
			reapplies += 1
			last_apply = now
		frames += 1
		now += dt_ms
	return [reapplies, frames]

func _initialize() -> void:
	print("=== verify_fall_altrate (G-FALL-ALTRATE) ===")
	var thr: float = CS.FALL_THROTTLE_VSPEED
	var tms: int = CS.FALL_THROTTLE_MS
	print("  FALL_THROTTLE_VSPEED=%.1f b/s  FALL_THROTTLE_MS=%d  | flags default: CAMFAR_HOLD=%s ATMO_THROTTLE=%s RING_HOLD=%s"
		% [thr, tms, str(CS.FP_FALL_CAMFAR_HOLD), str(CS.FP_FALL_ATMO_THROTTLE), str(CS.FP_FALL_RING_HOLD)])

	# --- flags byte-off by default (the shipped build is byte-identical; live A/B seds them on one at a time) ---
	_ok(CS.FP_FALL_CAMFAR_HOLD == false, "DEFAULT: FP_FALL_CAMFAR_HOLD is false (byte-off)")
	_ok(CS.FP_FALL_ATMO_THROTTLE == false, "DEFAULT: FP_FALL_ATMO_THROTTLE is false (byte-off)")
	_ok(CS.FP_FALL_RING_HOLD == false, "DEFAULT: FP_FALL_RING_HOLD is false (byte-off)")

	# --- radial_speed helper: dt ≤ 0 ⇒ 0; else |Δd|/dt ---
	_ok(FT.radial_speed(6371.0, 6371.0, 0.0) == 0.0, "radial_speed: dt=0 ⇒ 0 (no spurious speed)")
	_ok(absf(FT.radial_speed(7000.0, 6971.0, 1.0) - 29.0) < 1e-6, "radial_speed: 29 b in 1 s ⇒ 29 b/s")
	_ok(absf(FT.radial_speed(6971.0, 7000.0, 0.5) - 58.0) < 1e-6, "radial_speed: |Δ| symmetric (climb) ⇒ 58 b/s")

	# --- is_fast threshold ---
	_ok(not FT.is_fast(0.0), "is_fast: hover (0) is NOT fast")
	_ok(not FT.is_fast(thr), "is_fast: exactly at threshold is NOT fast (strict >)")
	_ok(FT.is_fast(thr + 0.01), "is_fast: just above threshold IS fast")

	# --- should_reapply contract ---
	_ok(FT.should_reapply(false, 1000.0, 0) == true, "BYTE-OFF: flag off ⇒ reapply even at huge speed / 0 ms")
	_ok(FT.should_reapply(true, 0.0, 0) == true, "CONVERGE: hover (0 b/s) ⇒ reapply every frame (exact)")
	_ok(FT.should_reapply(true, thr, 0) == true, "CONVERGE: at threshold ⇒ reapply every frame (exact)")
	_ok(FT.should_reapply(true, thr + 5.0, tms - 1) == false, "THROTTLE: fast + < MS elapsed ⇒ HOLD")
	_ok(FT.should_reapply(true, thr + 5.0, tms) == true, "THROTTLE: fast + MS elapsed ⇒ reapply")
	_ok(FT.should_reapply(true, 10000.0, tms) == true, "THROTTLE: extreme speed still reapplies once MS elapsed")

	# --- BYTE-OFF end-to-end: flag off ⇒ one reapply PER FRAME (scales with fps — the shipped behaviour) ---
	var off60 := _sim(false, 30.0, 60.0, 1000)
	_ok(off60[0] == off60[1], "BYTE-OFF: flag off ⇒ reapply count == frame count (%d == %d)" % [off60[0], off60[1]])

	# --- CONVERGENCE end-to-end: fast-flag on but SLOW motion ⇒ still one reapply per frame (exact value) ---
	var slow := _sim(true, thr - 0.5, 60.0, 1000)
	_ok(slow[0] == slow[1], "CONVERGE: below-threshold motion ⇒ reapply every frame (%d == %d, exact)" % [slow[0], slow[1]])

	# --- BOUNDED + RATE/FPS-INDEPENDENT: fast descent, vary rate & fps ⇒ reapply count stays ≈ window/MS ---
	var expect := int(1000 / tms) + 1                         # ≈ window/MS re-applies (+1 for the t=0 apply)
	var a := _sim(true, 30.0, 60.0, 1000)                     # 29-b/s free-fall, 60 fps
	var b := _sim(true, 200.0, 60.0, 1000)                    # 200-b/s plunge, 60 fps (much faster descent)
	var c := _sim(true, 30.0, 7.0, 1000)                      # 29-b/s free-fall, collapsed 7 fps
	var e := _sim(true, 200.0, 7.0, 1000)                     # 200-b/s plunge, 7 fps
	print("  fast-descent reapplies over 1000 ms: (30b/s,60fps)=%d  (200b/s,60fps)=%d  (30b/s,7fps)=%d  (200b/s,7fps)=%d  | expect≈%d  (off@60fps=%d)"
		% [a[0], b[0], c[0], e[0], expect, off60[0]])
	# Independent of DESCENT RATE at a fixed fps (the CORE property — re-apply rate no longer scales with |dAlt/dt|).
	_ok(a[0] == b[0], "RATE-INDEP: 30 b/s and 200 b/s give the SAME reapply count at 60 fps (%d == %d)" % [a[0], b[0]])
	_ok(c[0] == e[0], "RATE-INDEP: 30 b/s and 200 b/s give the SAME reapply count at 7 fps (%d == %d)" % [c[0], e[0]])
	# BOUNDED: every case is ≤ window/MS+1 (the throttle ceiling) AND ≤ its own frame count. At a low fps whose frame
	# already exceeds MS the ceiling is the frame count itself (still bounded, and cheap — few frames). Never per-frame
	# when the frame is shorter than MS (the 60-fps case: 10 vs 59 shipped).
	_ok(a[0] <= expect and c[0] <= expect, "BOUNDED: fast reapply count ≤ window/MS+1 (%d, %d ≤ %d) at both fps" % [a[0], c[0], expect])
	_ok(a[0] < off60[0] / 3, "BOUNDED: at 60 fps the throttle cuts the re-write rate ≥ 3× vs the shipped per-frame path (%d << %d)" % [a[0], off60[0]])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
