extends SceneTree
## COSMOS-PERF FALL-SCALE gate — G-FALL-SCALE (flags FP_FALL_SHELL_OFF + FP_FALL_SCALE_FREEZE / FP_FALL_FREEZE_CAM /
## FP_FALL_FREEZE_RING, shared core FallThrottle.should_reapply_band / band_index). Proves the two fall-from-orbit
## bisect contracts on the PURE decision cores (no engine deps), the way the live consumers route through them:
##
##   • FP_FALL_SHELL_OFF: hide the additive atmosphere shell while |radial speed| > SHELL_OFF_VSPEED. The gate pins
##     the threshold sits BETWEEN a constant-altitude orbit/hover (radial ≈ 0 ⇒ shell stays visible ⇒ orbit
##     byte-identical) and the slowest real fall (~7 b/s ⇒ shell hidden). Off ⇒ shell always visible (byte-identical).
##   • FP_FALL_SCALE_FREEZE: band the camera-planes + far-ring scale writes. flag off ⇒ reapply EVERY frame
##     (byte-identical); slow/steady ⇒ reapply every frame (exact convergence — orbit/hover untouched); fast fall ⇒
##     reapply ONCE PER altitude BAND (re-apply COUNT ∝ |Δaltitude|/band, INDEPENDENT of frame rate AND descent rate).
##
## RUN (no flags need toggling — the gate drives the pure cores; every flag stays at its false/true default = byte-off):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_fall_scale.gd
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

## Simulate a straight fall from d_hi down to d_lo at `vspeed` b/s and `fps` fps, driving should_reapply_band each
## frame with the band anchor carried at the last re-apply. Returns [reapply_count, frame_count]. Deterministic.
func _sim_band(flag_on: bool, vspeed: float, fps: float, d_hi: float, d_lo: float, band: float) -> Array:
	var d := d_hi
	var step := vspeed / fps                          # blocks of altitude per frame
	var last_d := -1.0
	var reapplies := 0
	var frames := 0
	while d >= d_lo:
		if FT.should_reapply_band(flag_on, vspeed, d, last_d, band):
			reapplies += 1
			last_d = d
		frames += 1
		d -= step
	return [reapplies, frames]

func _initialize() -> void:
	print("=== verify_fall_scale (G-FALL-SCALE) ===")
	var band: float = CS.FALL_FREEZE_BAND
	var thr: float = CS.FALL_THROTTLE_VSPEED
	var soff: float = CS.SHELL_OFF_VSPEED
	print("  FALL_FREEZE_BAND=%.1f b  FALL_THROTTLE_VSPEED=%.1f b/s  SHELL_OFF_VSPEED=%.1f b/s | defaults: SHELL_OFF=%s SCALE_FREEZE=%s FREEZE_CAM=%s FREEZE_RING=%s"
		% [band, thr, soff, str(CS.FP_FALL_SHELL_OFF), str(CS.FP_FALL_SCALE_FREEZE), str(CS.FP_FALL_FREEZE_CAM), str(CS.FP_FALL_FREEZE_RING)])

	# --- byte-off defaults (the shipped build is byte-identical; live A/B seds the two master flags on) ---
	_ok(CS.FP_FALL_SHELL_OFF == false, "DEFAULT: FP_FALL_SHELL_OFF is false (byte-off)")
	_ok(CS.FP_FALL_SCALE_FREEZE == false, "DEFAULT: FP_FALL_SCALE_FREEZE is false (byte-off)")

	# --- SHELL_OFF threshold sits between orbit/hover (≈0) and the slowest fall (~7 b/s) ---
	_ok(FT.radial_speed(6371.0, 6371.0, 0.5) <= soff, "SHELL-OFF: hover/orbit radial ≈ 0 ≤ threshold ⇒ shell stays visible")
	_ok(FT.radial_speed(7000.0, 6993.0, 1.0) > soff, "SHELL-OFF: a 7 b/s fall > threshold ⇒ shell hidden")
	_ok(soff > 0.0 and soff < 7.0, "SHELL-OFF: threshold strictly between 0 and the 7 b/s slow-fall floor")

	# --- band_index: quantizes distance into BAND-wide shells; band ≤ 0 guarded to a single band ---
	_ok(FT.band_index(0.0, band) == 0, "band_index: d=0 ⇒ band 0")
	_ok(FT.band_index(band - 0.001, band) == 0, "band_index: just below one band ⇒ band 0")
	_ok(FT.band_index(band + 0.001, band) == 1, "band_index: just above one band ⇒ band 1")
	_ok(FT.band_index(6371.0, band) == int(floor(6371.0 / band)), "band_index: matches floor(d/band)")
	_ok(FT.band_index(1234.0, 0.0) == 0, "band_index: band ≤ 0 ⇒ single band (no div-by-zero)")

	# --- should_reapply_band contract ---
	_ok(FT.should_reapply_band(false, 1000.0, 6371.0, 6371.0, band) == true, "BYTE-OFF: flag off ⇒ reapply even at huge speed / same band")
	_ok(FT.should_reapply_band(true, 0.0, 6371.0, 9999.0, band) == true, "CONVERGE: hover (0 b/s) ⇒ reapply (exact) regardless of band")
	_ok(FT.should_reapply_band(true, thr, 6371.0, 9999.0, band) == true, "CONVERGE: at threshold ⇒ reapply (exact)")
	_ok(FT.should_reapply_band(true, thr + 5.0, 6371.0, -1.0, band) == true, "FIRST: fast + no prior apply ⇒ reapply")
	# Anchor both samples inside ONE band [k·band, (k+1)·band) to test HOLD vs CROSS unambiguously.
	var band_lo: float = floor(6371.0 / band) * band                # the low edge of 6371's band
	_ok(FT.should_reapply_band(true, thr + 5.0, band_lo + band * 0.1, band_lo + band * 0.9, band) == false, "HOLD: fast + same band ⇒ HOLD (no re-fit)")
	_ok(FT.should_reapply_band(true, thr + 5.0, band_lo - band * 0.1, band_lo + band * 0.5, band) == true, "CROSS: fast + crossed a band edge ⇒ reapply")

	# --- end-to-end BYTE-OFF: flag off ⇒ one reapply PER FRAME (the shipped every-frame write) ---
	var off := _sim_band(false, 29.0, 60.0, 7000.0, 6371.0, band)
	_ok(off[0] == off[1], "BYTE-OFF: flag off ⇒ reapply count == frame count (%d == %d)" % [off[0], off[1]])

	# --- end-to-end CONVERGENCE: on but SLOW (below threshold) ⇒ still one reapply per frame (exact) ---
	var slow := _sim_band(true, thr - 0.5, 60.0, 7000.0, 6371.0, band)
	_ok(slow[0] == slow[1], "CONVERGE: below-threshold ⇒ reapply every frame (%d == %d, exact)" % [slow[0], slow[1]])

	# --- end-to-end BANDED: fast fall over a fixed Δaltitude ⇒ reapply COUNT ≈ Δalt/band+1, INDEPENDENT of fps ---
	var d_hi := 7000.0
	var d_lo := 6371.0
	var expect := int(floor((d_hi - d_lo) / band)) + 1               # bands crossed + the first apply
	var f60 := _sim_band(true, 29.0, 60.0, d_hi, d_lo, band)         # 29 b/s, 60 fps
	var f7 := _sim_band(true, 29.0, 7.0, d_hi, d_lo, band)           # 29 b/s, collapsed 7 fps
	var fast := _sim_band(true, 200.0, 60.0, d_hi, d_lo, band)       # 200 b/s plunge, 60 fps
	print("  banded reapplies over Δalt=%.0f (band=%.0f): (29b/s,60fps)=%d  (29b/s,7fps)=%d  (200b/s,60fps)=%d  | expect≈%d  (off@60fps=%d frames)"
		% [d_hi - d_lo, band, f60[0], f7[0], fast[0], expect, off[1]])
	_ok(absi(f60[0] - expect) <= 1, "BANDED: fast fall reapply count ≈ Δalt/band+1 (%d ≈ %d)" % [f60[0], expect])
	_ok(absi(f60[0] - f7[0]) <= 1, "FPS-INDEP: same fall gives ~same reapply count at 60 fps and 7 fps (%d ≈ %d)" % [f60[0], f7[0]])
	_ok(absi(f60[0] - fast[0]) <= 1, "RATE-INDEP: 29 b/s and 200 b/s give ~same reapply count at 60 fps (%d ≈ %d)" % [f60[0], fast[0]])
	_ok(f60[0] < off[0] / 4, "BOUNDED: at 60 fps the band cuts the re-write rate ≥ 4× vs the shipped per-frame path (%d << %d)" % [f60[0], off[0]])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
