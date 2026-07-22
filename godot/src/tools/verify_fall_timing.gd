extends SceneTree
## COSMOS-PERF FALL-TIMING gate — G-FALL-TIMING (flag FP_FALL_TIMING). FP_FALL_TIMING is a DIAGNOSTIC instrument:
## it wraps the major per-frame free-fall CPU segments in Time.get_ticks_usec() deltas and publishes the per-segment
## window-MAX µs in the telemetry so a live fall names the hotspot. This gate proves the two contracts headless:
##
##   • BYTE-OFF: the shipped default is FP_FALL_TIMING == false, and the cross-node push seam ft_record() is a
##     no-op off the flag ⇒ the accumulator stays empty ⇒ fall_timing() returns {} ⇒ NO t_*_us telemetry keys
##     (the RemoteBridge merge is empty-dict-guarded ⇒ byte-identical telemetry stream).
##   • PLUMBING: the low-level accumulator (_ft_max, driven by the flag-gated segment wrappers when the flag IS on)
##     records a per-key MAX, fall_timing() returns exactly those keys, and RESETS for the next window on read.
##
## RUN (no flag toggling needed — the plumbing is exercised through _ft_max directly; the flag default stays false):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_fall_timing.gd
## Exits 0 all-pass / 1 on any failure.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const PlayerCls := preload("res://src/player/player.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_fall_timing (G-FALL-TIMING) ===")
	print("  FP_FALL_TIMING default = %s" % str(CS.FP_FALL_TIMING))

	# --- BYTE-OFF: the shipped build must ship the flag OFF ---
	_ok(CS.FP_FALL_TIMING == false, "DEFAULT: FP_FALL_TIMING is false (byte-off)")

	var p: Player = PlayerCls.new()

	# --- fresh player: nothing recorded ⇒ fall_timing() is {} (merges nothing ⇒ byte-identical) ---
	_ok(p.fall_timing().is_empty(), "EMPTY: a fresh player's fall_timing() is {} (no keys)")

	# --- BYTE-OFF push seam: ft_record() is gated on the flag ⇒ off, it records NOTHING ---
	p.ft_record("t_sky_us", 999)
	p.ft_record("t_scaledbody_us", 999)
	p.ft_record("t_farring_us", 999)
	_ok(p.fall_timing().is_empty(), "BYTE-OFF: ft_record() is a no-op with the flag off ⇒ still {} (no cross-node keys)")

	# --- PLUMBING: the low-level accumulator (what the flag-gated segment wrappers call when ON) records MAX ---
	p._ft_max("t_move_us", 120)
	p._ft_max("t_move_us", 80)          # smaller ⇒ MAX holds 120
	p._ft_max("t_move_us", 200)         # larger  ⇒ MAX rises to 200
	p._ft_max("t_coast_us", 55)
	p._ft_max("t_stream_us", 3)
	p._ft_max("n_coast_calls", 4)
	var ft: Dictionary = p.fall_timing()
	_ok(not ft.is_empty(), "PLUMBING: after _ft_max, fall_timing() is non-empty")
	_ok(int(ft.get("t_move_us", -1)) == 200, "PLUMBING: t_move_us holds the window MAX (200)")
	_ok(int(ft.get("t_coast_us", -1)) == 55, "PLUMBING: t_coast_us recorded (55)")
	_ok(int(ft.get("t_stream_us", -1)) == 3, "PLUMBING: t_stream_us recorded (3)")
	_ok(int(ft.get("n_coast_calls", -1)) == 4, "PLUMBING: n_coast_calls recorded (4)")

	# --- RESET: fall_timing() clears the window on read ⇒ the next call is {} again ---
	_ok(p.fall_timing().is_empty(), "RESET: fall_timing() clears the accumulator on read ⇒ next window starts empty")

	# --- the full expected key set is representable (a smoke that every published segment key round-trips) ---
	for k in ["t_move_us", "t_coast_us", "t_stream_us", "t_nav_us", "t_att_us", "t_pushbodies_us", "t_aim_us",
			"t_scaledbody_us", "t_farring_us", "t_sky_us", "n_coast_calls"]:
		p._ft_max(k, 1)
	var full: Dictionary = p.fall_timing()
	var missing := PackedStringArray()
	for k in ["t_move_us", "t_coast_us", "t_stream_us", "t_nav_us", "t_att_us", "t_pushbodies_us", "t_aim_us",
			"t_scaledbody_us", "t_farring_us", "t_sky_us", "n_coast_calls"]:
		if not full.has(k):
			missing.append(String(k))
	_ok(missing.is_empty(), "KEYSET: all 11 fall-timing keys round-trip (missing: %s)" % ",".join(missing))

	p.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
