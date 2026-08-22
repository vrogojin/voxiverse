extends SceneTree
## COSMOS-FALL-STREAM-PACING gate (docs/COSMOS-FALL-STREAM-PACING-DESIGN.md, task #144) —
## FP_STREAM_FALL_PACE (§2.1, round-robin the 3 heavy update_streaming tail drivers on a fast descent) +
## FP_REENTRY_VIEW_RAMP (§2.2, bounded-step near-view re-growth on the approach anchor). Modeled on
## verify_stream_tick.gd (bare WorldManager, self-describing on the compiled flag, headless).
##
##   G-SFP-PACE   flag on, rate FORCED to -30 (frozen against the estimator via debug_set_alt_rate): 6 tail
##                frames ⇒ each of skin/tex/relief advances EXACTLY 2 (round-robin, full coverage, one per
##                frame). Off: each advances 6 (shipped — every driver every frame).
##   G-SFP-CALM   rate forced to 0 (frozen, calm): all three counters advance every frame regardless of the
##                flag — pacing is provably dormant when not plunging (the orbit-settled / walking protection).
##   G-SFP-EST    estimator plumbing (NOT frozen — the real _stream_pace_update_rate): under either flag, a
##                teleport-sized jump between two real-wall-clock-spaced calls leaves debug_alt_rate() unmoved
##                (STREAM_PACE_RATE_CLAMP rejection); a plausible gradual descent moves it negative. Both flags
##                off ⇒ the estimator never runs at all ⇒ debug_alt_rate() stays 0 (byte-identical dormant state).
##   G-SFP-FLOOR  copy of G-MTP-FLOOR (verify_stream_tick.gd) driven with pacing FORCED ENGAGED — block_id_at
##                over a column span is invariant across paced update_streaming calls (the paced blocks write
##                NO collision state — the fall-through-safety invariant, pinned).
##   G-AVR-CLAMP  pure-static arm on CubeSphere.anchor_grow_clamp: growth bounded to ANCHOR_GROW_STEP per write
##                and monotone, reaching `full` in ceil((full-lo)/STEP) writes, ON; a single write reaches full
##                OFF (the shipped jump, self-describing). Shrink is never clamped; descending_fast=false or
##                last_vd<0 (no prior write) is always the identity, both arms.
##
## RUN (OFF arm — the shipped default):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_stream_fall_pace.gd
## RUN (ON arm):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_STREAM_FALL_PACE := false/const FP_STREAM_FALL_PACE := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_REENTRY_VIEW_RAMP := false/const FP_REENTRY_VIEW_RAMP := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_stream_fall_pace.gd
## Exits 0 all-pass / 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _bare_world(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)
	return w

func _initialize() -> void:
	print("=== verify_stream_fall_pace (FP_STREAM_FALL_PACE / FP_REENTRY_VIEW_RAMP — de-orbit fall stream pacing) ===")
	var pace_on := CubeSphere.FP_STREAM_FALL_PACE
	var ramp_on := CubeSphere.FP_REENTRY_VIEW_RAMP
	print("  flags: FP_STREAM_FALL_PACE=%s FP_REENTRY_VIEW_RAMP=%s FACETED=%s | STREAM_FALL_PACE_VY=%.1f STREAM_PACE_RATE_CLAMP=%.1f ANCHOR_GROW_STEP=%d"
		% [str(pace_on), str(ramp_on), str(CubeSphere.FACETED), CubeSphere.STREAM_FALL_PACE_VY, CubeSphere.STREAM_PACE_RATE_CLAMP, CubeSphere.ANCHOR_GROW_STEP])

	# ---------------------------------------------------------------------------------------------------------------
	# G-SFP-PACE / G-SFP-CALM — the round-robin phase gate, driven with the rate FROZEN (debug_set_alt_rate) so a
	# headless sub-ms wall-clock can never poison the forced value. debug_pace_runs() counts tail frames on which
	# each driver was ALLOWED to run — it advances regardless of whether the driver object itself exists (a bare
	# world has none), so it exercises the gating logic in isolation, exactly like debug_tail_runs() does for TICK_ONCE.
	# ---------------------------------------------------------------------------------------------------------------
	var w := _bare_world("Pace")
	var p := Vector3(0.0, 100.0, 0.0)

	w.debug_set_alt_rate(-30.0, true)   # frozen well below -STREAM_FALL_PACE_VY(15) ⇒ a plunge, immune to the estimator
	var base := w.debug_pace_runs()
	for i in range(6):
		w.debug_set_tail_frame(-100 - i)   # force a "new render frame" each call (defensive — FP_STREAM_TICK_ONCE is off by default)
		w.update_streaming(p)
	var runs6 := w.debug_pace_runs()
	var d_skin: int = runs6["skin"] - base["skin"]
	var d_tex: int = runs6["tex"] - base["tex"]
	var d_relief: int = runs6["relief"] - base["relief"]
	if pace_on:
		_ok(d_skin == 2 and d_tex == 2 and d_relief == 2,
			"G-SFP-PACE(on): 6 tail frames at a frozen plunge rate ⇒ each of skin/tex/relief advances EXACTLY 2 (round-robin) — got skin=%d tex=%d relief=%d" % [d_skin, d_tex, d_relief])
	else:
		_ok(d_skin == 6 and d_tex == 6 and d_relief == 6,
			"G-SFP-PACE(off): 6 tail frames ⇒ each driver advances 6 (shipped — every driver every frame) — got skin=%d tex=%d relief=%d" % [d_skin, d_tex, d_relief])

	w.debug_set_alt_rate(0.0, true)   # frozen calm — never a plunge, regardless of the flag
	var base2 := w.debug_pace_runs()
	for i in range(6):
		w.debug_set_tail_frame(-200 - i)
		w.update_streaming(p)
	var runs2 := w.debug_pace_runs()
	var c_skin: int = runs2["skin"] - base2["skin"]
	var c_tex: int = runs2["tex"] - base2["tex"]
	var c_relief: int = runs2["relief"] - base2["relief"]
	_ok(c_skin == 6 and c_tex == 6 and c_relief == 6,
		"G-SFP-CALM: rate 0 (not descending) ⇒ all three counters advance every frame regardless of the flag — got skin=%d tex=%d relief=%d" % [c_skin, c_tex, c_relief])

	# ---------------------------------------------------------------------------------------------------------------
	# G-SFP-EST — the estimator itself (NOT frozen). Real OS.delay_msec gaps between calls make dt large enough
	# (~ms) that the implied rate is deterministic regardless of headless CPU jitter: a huge one-tick altitude
	# jump implies a rate orders of magnitude above STREAM_PACE_RATE_CLAMP (rejected); a small per-tick step
	# implies a plausible descent rate well under it (accepted, moves negative). Fresh worlds so no state leaks
	# from the frozen G-SFP-PACE/CALM runs above.
	# ---------------------------------------------------------------------------------------------------------------
	var w2 := _bare_world("Est")
	if pace_on or ramp_on:
		w2.update_streaming(Vector3(0.0, 1000.0, 0.0))
		var r0 := w2.debug_alt_rate()
		OS.delay_msec(2)
		w2.update_streaming(Vector3(0.0, -50000.0, 0.0))   # a ~-2.5e7 b/s implied jump ⇒ far above the clamp ⇒ rejected
		var r1 := w2.debug_alt_rate()
		_ok(absf(r1 - r0) < 1.0e-6, "G-SFP-EST(on): a teleport-sized altitude jump leaves debug_alt_rate() unmoved (STREAM_PACE_RATE_CLAMP=%.0f rejection, r0=%.3f r1=%.3f)" % [CubeSphere.STREAM_PACE_RATE_CLAMP, r0, r1])

		var w3 := _bare_world("Est2")
		var y := 1000.0
		w3.update_streaming(Vector3(0.0, y, 0.0))
		for i in range(10):
			OS.delay_msec(2)
			y -= 0.2   # ~-100 b/s implied per step — plausible descent, well under the clamp
			w3.update_streaming(Vector3(0.0, y, 0.0))
		_ok(w3.debug_alt_rate() < 0.0, "G-SFP-EST(on): a gradual plausible descent moves debug_alt_rate() negative (%.3f)" % w3.debug_alt_rate())
		w3.queue_free()
	else:
		w2.update_streaming(Vector3(0.0, 1000.0, 0.0))
		OS.delay_msec(2)
		w2.update_streaming(Vector3(0.0, -50000.0, 0.0))
		_ok(w2.debug_alt_rate() == 0.0, "G-SFP-EST(off): both flags off ⇒ the estimator never runs — debug_alt_rate() stays 0 regardless of motion (byte-identical dormant state)")
	w2.queue_free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-SFP-FLOOR (the fall-through-safety invariant — verify_stream_tick.gd's G-MTP-FLOOR precedent) — driven
	# with pacing FORCED ON (frozen fast-descent rate) so the paced blocks are actually exercised: block_id_at
	# over a column span is invariant across paced update_streaming calls (the paced drivers write no collision
	# state — physics is analytic and never reads them).
	# ---------------------------------------------------------------------------------------------------------------
	var w4 := _bare_world("Floor")
	w4.debug_set_alt_rate(-30.0, true)
	var q_ok := true
	for x in range(-3, 4):
		for z in range(-3, 4):
			var col_solid := 0
			for y2 in range(-4, 40):
				if w4.block_id_at(Vector3i(x, y2, z)) != 0:
					col_solid += 1
			w4.update_streaming(Vector3(float(x), 100.0, float(z)))
			var col_solid2 := 0
			for y2 in range(-4, 40):
				if w4.block_id_at(Vector3i(x, y2, z)) != 0:
					col_solid2 += 1
			if col_solid != col_solid2:
				q_ok = false
	_ok(q_ok, "G-SFP-FLOOR: block_id_at is invariant across PACED update_streaming calls (paced drivers write no collision state — no fall-through)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-AVR-CLAMP — pure-static arm on CubeSphere.anchor_grow_clamp (headless-testable regardless of the driver).
	# ---------------------------------------------------------------------------------------------------------------
	var full := 128
	var lo0 := 0
	if ramp_on:
		var vd := lo0
		var bounded := true
		var monotone := true
		var writes := 0
		while vd < full and writes < 1000:
			var prev := vd
			vd = CubeSphere.anchor_grow_clamp(full, vd, true)
			if vd - prev > CubeSphere.ANCHOR_GROW_STEP:
				bounded = false
			if vd < prev:
				monotone = false
			writes += 1
		var expect_writes := int(ceil(float(full - lo0) / float(CubeSphere.ANCHOR_GROW_STEP)))
		_ok(bounded, "G-AVR-CLAMP(on): growth is bounded to ANCHOR_GROW_STEP(%d) blocks per write" % CubeSphere.ANCHOR_GROW_STEP)
		_ok(monotone, "G-AVR-CLAMP(on): growth is monotone non-decreasing")
		_ok(vd == full, "G-AVR-CLAMP(on): growth reaches full(%d) (writes=%d)" % [full, writes])
		_ok(writes == expect_writes, "G-AVR-CLAMP(on): reaches full in ceil((full-lo)/STEP)=%d writes (got %d)" % [expect_writes, writes])
	else:
		var jumped := CubeSphere.anchor_grow_clamp(full, lo0, true) == full
		_ok(jumped, "G-AVR-CLAMP(off): FP_REENTRY_VIEW_RAMP off ⇒ growth is NOT staged — one write reaches full(%d) (byte-identical, the shipped jump)" % full)
	# shrink is never clamped (both arms — anchor_grow_clamp only ever clamps GROWTH)
	var shrink_id := CubeSphere.anchor_grow_clamp(10, 100, true) == 10
	_ok(shrink_id, "G-AVR-CLAMP: shrinking (want_vd <= last_vd) is never clamped (identity) — both arms")
	# descending_fast=false ⇒ identity regardless of jump size (both arms)
	var calm_id := CubeSphere.anchor_grow_clamp(128, 0, false) == 128
	_ok(calm_id, "G-AVR-CLAMP: descending_fast=false ⇒ identity (no clamp) even for a full jump — both arms")
	# last_vd < 0 (no prior write) ⇒ identity — the first write is never staged (both arms)
	var first_id := CubeSphere.anchor_grow_clamp(128, -1, true) == 128
	_ok(first_id, "G-AVR-CLAMP: last_vd < 0 (no prior write) ⇒ identity — the first write is never staged — both arms")

	w.queue_free(); w4.queue_free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
