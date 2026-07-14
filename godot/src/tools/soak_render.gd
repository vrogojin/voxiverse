extends SceneTree
## TIER A — NATIVE *RENDERED* SOAK (docs/COSMOS-FP-M2-DESIGN.md testing-tier A; task #104).
##
## WHY THIS EXISTS (what our other verifiers cannot see)
## Every existing verify_*.gd runs `--headless`, i.e. under Godot's DUMMY display+rendering driver: NO GL
## context, NO shader compile, NO texture/framebuffer allocation, NO draw. That path proves *logic* invariants
## (terrain stackup, crossing correctness, backlog) but is STONE BLIND to the whole class of failures that only
## appear once a frame is actually DRAWN:
##   * a shader that fails to COMPILE on the GL Compatibility backend (the SAME renderer web ships),
##   * geometry that silently DISAPPEARS (mesher/material regression → a black or empty frame),
##   * a heap that balloons UNDER RENDER (texture + framebuffer + vertex-buffer VRAM that headless never allocs) —
##     the NEVER-OOM-ON-WEB signal (docs/COSMOS-FP-M2-HEAP-AB.md), which headless MEMORY_STATIC alone misses.
## This driver boots the REAL game (res://scenes/main.tscn — the shipping faceted engine, whatever flags are set),
## renders REAL frames through the REAL Compatibility pipeline, walks a fixed path, and every frame records the
## frame-time series + the render-heap series, periodically saving a PNG so a golden-compare can catch a gross
## visual regression (missing terrain / black frame / broken shader).
##
## THE RENDER PATH HERE (read before trusting a number)
## Our CI host has NO usable GPU. This is meant to run under a virtual X server (Xvfb) + Mesa software GL
## (llvmpipe / swrast): see scripts/render-soak.sh. That exercises the TRUE render path (project is locked to
## `gl_compatibility`, the SAME backend web uses) so it is a strong proxy for VISUALS, SHADER-COMPILE, and
## HEAP-UNDER-RENDER. It is NOT a proxy for FPS: llvmpipe rasterises on the CPU, so every frame-time number below
## is CPU-RENDERED and NON-REPRESENTATIVE of real GPU/browser FPS — it is recorded to catch a *pathological*
## regression (a frame that suddenly costs 10x), never as an absolute fps figure. Labelled as such everywhere.
##
## EXIT CODE — quits 0 on a clean walk; NONZERO only on a genuine render failure:
##   * a frame that fails to render / read back (engine assertion, GL context loss), OR
##   * an ALL-BLACK captured frame (nothing drew — broken shader / vanished geometry), OR
##   * a render-heap peak over a GENEROUS ceiling (the never-OOM-under-render guard).
## It does NOT gate on frame-time (that would be asserting a fake fps on a CPU rasteriser).
##
## RUN: scripts/render-soak.sh  (sets up Xvfb + llvmpipe in Docker and points SOAK_OUT at build/soak/).
## Direct (deps already present):
##   xvfb-run -a -s "-screen 0 1280x720x24" \
##     LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe SOAK_OUT=/abs/out \
##     docker/engine/bin/godot.linuxbsd.editor.x86_64 --path godot \
##       --rendering-driver opengl3 --resolution 1280x720 \
##       --script res://src/tools/soak_render.gd

# ---- walk / capture configuration ----
const BOOT_WAIT_FRAMES := 1200      # max frames to wait for the scene to boot + ShaderPrewarm to unfreeze the player
const SETTLE_FRAMES := 90           # frames to let the near field stream in before the walk (terrain must be present)
const WALK_FRAMES := 900            # frames of driven motion (the soak body)
const SCREENSHOT_EVERY := 60        # capture one PNG every N walk frames
const WALK_RADIUS := 34.0           # radius (blocks) of the circular path around the spawn anchor (stays in-facet)
const EYE_ABOVE := 2.2              # camera height above the sampled surface, blocks

# ---- ceilings (GENEROUS — only a pathological regression trips these) ----
const HEAP_STATIC_CEIL_MB := 3072.0     # MEMORY_STATIC ceiling (never-OOM guard; native peak is normally a few 100 MB)
const RENDER_MEM_CEIL_MB := 3072.0      # texture + buffer VRAM ceiling (the render-heap signal headless never sees)
const BLACK_MEAN_FLOOR := 0.012         # mean luminance below this ⇒ frame is "black" (nothing drew). [0..1]
const WORST_FRAME_SPIKE_MS := 8000.0    # a single frame over this ⇒ treated as a render stall/hang (CPU-rendered, huge budget)

var _fail := 0
var _fail_msgs: Array[String] = []
func _fatal(m: String) -> void:
	_fail += 1
	_fail_msgs.append(m)
	push_error("[SOAK-RENDER] FAIL: " + m)
	print("[SOAK-RENDER] FAIL: ", m)

# recorded series — one row per rendered walk frame.
# {i, t_ms, cpu_ms(NON-REPRESENTATIVE), fps(NON-REPRESENTATIVE), mem_static_mb, tex_mem_mb, buf_mem_mb, objects}
var _series: Array = []
var _shots: Array = []           # {i, path, mean_lum, black}
var _out_dir := ""
var _peak_static_mb := 0.0
var _peak_render_mb := 0.0
var _worst_cpu_ms := 0.0

func _initialize() -> void:
	print("=== soak_render (Tier A — native RENDERED soak) ===")

	# --- guard: we MUST be on a real rendering driver, not the headless dummy (else "rendered" is a lie). ---
	var driver := RenderingServer.get_rendering_device()
	var dummy := (RenderingServer.get_video_adapter_name() == "" and driver == null)
	var adapter := RenderingServer.get_video_adapter_name()
	print("  video adapter: '%s'  (rendering_device=%s)" % [adapter, "present" if driver != null else "null (GL/Compat is normal)"])
	# The GL Compatibility backend has NO RenderingDevice (that is Vulkan-only) — a null device is EXPECTED and
	# correct here. The real "are we rendering?" test is the dummy-driver name below.
	if adapter == "" or adapter.to_lower().find("dummy") != -1:
		_fatal("no real rendering driver (adapter='%s') — this must run WITHOUT --headless, with --rendering-driver opengl3." % adapter)
		_finish(); return

	_out_dir = _resolve_out_dir()
	print("  output dir: %s" % _out_dir)

	# --- boot the REAL game scene (the shipping faceted engine — we do NOT touch its flags). ---
	var scene_res := load("res://scenes/main.tscn")
	if scene_res == null:
		_fatal("could not load res://scenes/main.tscn"); _finish(); return
	var scene: Node = scene_res.instantiate()
	get_root().add_child(scene)
	print("  main.tscn instanced; waiting for boot + ShaderPrewarm to unfreeze the player…")

	# --- wait for the player to exist AND ShaderPrewarm to finish (it flips player.frozen false via its callback). ---
	var player: Node3D = null
	var world: Node = null
	var booted := false
	for _i in range(BOOT_WAIT_FRAMES):
		await process_frame
		player = scene.get_node_or_null("Player") as Node3D
		world = scene.get_node_or_null("WorldManager")
		if player != null and world != null and not bool(player.get("frozen")):
			booted = true
			break
	if not booted or player == null or world == null:
		_fatal("scene did not boot within %d frames (player=%s world=%s frozen=%s) — ShaderPrewarm may have stalled." % [
			BOOT_WAIT_FRAMES, player != null, world != null, str(player.get("frozen")) if player != null else "n/a"])
		_finish(); return

	# --- TAKE OVER: freeze the player so its _physics_process does not fight our teleport; we drive streaming ourselves. ---
	player.set("frozen", true)
	var anchor: Vector3 = player.global_position
	print("  booted. spawn anchor = %s, using_module = %s" % [anchor, str(world.get("using_module"))])
	_snapshot_mem("boot")

	# --- settle: hold at the anchor and let the near field stream in so the first captured frame is not empty. ---
	for _s in range(SETTLE_FRAMES):
		if world.has_method("update_streaming"):
			world.update_streaming(player.global_position)
		await process_frame
	_snapshot_mem("settled")

	# --- the walk: a fixed circular path around the anchor (stays inside the active facet — no seam cross needed for
	#     a render/heap soak). The camera yaw pans with the path so the view sweeps fresh terrain each frame. ---
	await _walk(player, world, anchor)

	_snapshot_mem("post-walk")
	_dump_series()
	_summarize()
	_finish()

# -------------------------------------------------------------------------------------------------
func _walk(player: Node3D, world: Node, anchor: Vector3) -> void:
	var last_us := Time.get_ticks_usec()
	var shot_idx := 0
	for f in range(WALK_FRAMES):
		var ang := TAU * float(f) / float(WALK_FRAMES) * 3.0     # 3 full laps over the walk
		var px := anchor.x + cos(ang) * WALK_RADIUS
		var pz := anchor.z + sin(ang) * WALK_RADIUS
		var sy := anchor.y
		if world.has_method("surface_y"):
			var h: float = world.surface_y(px, pz)
			if is_finite(h) and absf(h) < 1.0e12:               # guard the wedge/void sentinel (1e18)
				sy = h + EYE_ABOVE
		player.global_position = Vector3(px, sy, pz)
		# look along the tangent, tilted slightly down onto the terrain, so the sweep shows ground + horizon.
		if player.has_method("set_initial_look"):
			player.set_initial_look(ang + PI * 0.5, -0.18)
		# drive native + GDScript-side streaming to follow us (player is frozen, so it won't do this itself).
		if world.has_method("update_streaming"):
			world.update_streaming(player.global_position)

		await process_frame

		# frame-cost sample (CPU-rendered under llvmpipe — NON-REPRESENTATIVE; recorded only to catch a stall spike).
		var now_us := Time.get_ticks_usec()
		var cpu_ms := float(now_us - last_us) / 1000.0
		last_us = now_us
		_worst_cpu_ms = maxf(_worst_cpu_ms, cpu_ms)
		var static_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		var tex_mb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
		var buf_mb := Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
		_peak_static_mb = maxf(_peak_static_mb, static_mb)
		_peak_render_mb = maxf(_peak_render_mb, tex_mb + buf_mb)
		_series.append({
			"i": f, "t_ms": Time.get_ticks_msec(),
			"cpu_ms": cpu_ms, "fps": Performance.get_monitor(Performance.TIME_FPS),
			"mem_static_mb": static_mb, "tex_mem_mb": tex_mb, "buf_mem_mb": buf_mb,
			"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		})
		# a per-frame stall spike is a render hang signal (huge budget — llvmpipe frames are slow but bounded).
		if cpu_ms > WORST_FRAME_SPIKE_MS:
			_fatal("render stall: frame %d took %.0f ms (> %.0f ms) — possible GL hang / infinite compile." % [
				f, cpu_ms, WORST_FRAME_SPIKE_MS])

		# periodic screenshot (frame_post_draw REQUIRED so the frame is fully finished before texture readback).
		if f % SCREENSHOT_EVERY == 0:
			await RenderingServer.frame_post_draw
			_capture(shot_idx, f)
			shot_idx += 1

# -------------------------------------------------------------------------------------------------
# Capture the viewport to a PNG and compute a mean-luminance black-frame detector (in-engine, so the soak
# fails on a black frame even when no external image tool is present; the golden-compare in the script is the
# perceptual layer on top of this).
func _capture(shot_idx: int, frame_no: int) -> void:
	var vp := get_root()
	if vp == null:
		_fatal("no root viewport for screenshot at frame %d" % frame_no); return
	var tex := vp.get_texture()
	if tex == null:
		_fatal("viewport has no texture at frame %d (render target not created?)" % frame_no); return
	var img := tex.get_image()
	if img == null or img.get_width() == 0 or img.get_height() == 0:
		_fatal("empty viewport image at frame %d (%s)" % [frame_no, str(img)]); return
	var mean_lum := _mean_luminance(img)
	var is_black := mean_lum < BLACK_MEAN_FLOOR
	var path := "%s/frame_%04d.png" % [_out_dir, shot_idx]
	var err := img.save_png(path)
	if err != OK:
		_fatal("save_png failed (err %d) for %s" % [err, path]); return
	_shots.append({"i": shot_idx, "frame": frame_no, "path": path, "mean_lum": mean_lum, "black": is_black})
	print("  [shot %02d] frame %d → %s  mean_lum=%.4f %s" % [
		shot_idx, frame_no, path, mean_lum, "*** BLACK ***" if is_black else ""])
	if is_black:
		_fatal("captured frame %d is BLACK (mean_lum %.4f < %.4f) — nothing rendered (broken shader / vanished geometry)." % [
			frame_no, mean_lum, BLACK_MEAN_FLOOR])

# Downsampled mean luminance over the frame (cheap; ~a few hundred taps), returns [0..1].
func _mean_luminance(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(min(w, h) / 48))
	var acc := 0.0
	var n := 0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := img.get_pixel(x, y)
			acc += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
			x += step
		y += step
	return acc / float(maxi(n, 1))

# -------------------------------------------------------------------------------------------------
func _snapshot_mem(label: String) -> void:
	var static_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var tex_mb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	var buf_mb := Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	var os_static := OS.get_static_memory_usage() / 1048576.0
	print("  [mem:%s] MEMORY_STATIC=%.1f MB  OS.static=%.1f MB  RENDER tex=%.1f MB buf=%.1f MB (tex+buf=%.1f)" % [
		label, static_mb, os_static, tex_mb, buf_mb, tex_mb + buf_mb])

func _dump_series() -> void:
	# CSV (frame-time + heap series) + JSON (series + shots + summary) so downstream tooling can scrape either.
	var csv := FileAccess.open("%s/soak_render_series.csv" % _out_dir, FileAccess.WRITE)
	if csv != null:
		csv.store_line("i,t_ms,cpu_ms_NONREP,fps_NONREP,mem_static_mb,tex_mem_mb,buf_mem_mb,render_mem_mb,objects")
		for r in _series:
			csv.store_line("%d,%d,%.3f,%.1f,%.2f,%.2f,%.2f,%.2f,%d" % [
				r["i"], r["t_ms"], r["cpu_ms"], r["fps"], r["mem_static_mb"], r["tex_mem_mb"], r["buf_mem_mb"],
				float(r["tex_mem_mb"]) + float(r["buf_mem_mb"]), r["objects"]])
		csv.close()
		print("  wrote %s/soak_render_series.csv (%d rows)" % [_out_dir, _series.size()])
	var js := FileAccess.open("%s/soak_render.json" % _out_dir, FileAccess.WRITE)
	if js != null:
		js.store_string(JSON.stringify({
			"series": _series, "shots": _shots,
			"peak_static_mb": _peak_static_mb, "peak_render_mb": _peak_render_mb, "worst_cpu_ms": _worst_cpu_ms,
			"note": "cpu_ms/fps are CPU-rendered under llvmpipe — NON-REPRESENTATIVE of real GPU/browser FPS.",
		}, "  "))
		js.close()

func _summarize() -> void:
	print("")
	print("  --- [SOAK-RENDER] SUMMARY ---")
	print("    frames rendered          : %d" % _series.size())
	print("    screenshots captured     : %d  (dir: %s)" % [_shots.size(), _out_dir])
	print("    non-black screenshots     : %d / %d" % [
		_shots.reduce(func(a, s): return a + (0 if s["black"] else 1), 0), _shots.size()])
	print("    peak MEMORY_STATIC       : %.1f MB   (ceiling %.0f MB)   [heap-under-render guard]" % [
		_peak_static_mb, HEAP_STATIC_CEIL_MB])
	print("    peak RENDER tex+buf mem  : %.1f MB   (ceiling %.0f MB)   [VRAM headless never allocates]" % [
		_peak_render_mb, RENDER_MEM_CEIL_MB])
	print("    worst CPU frame          : %.1f ms   [NON-REPRESENTATIVE — llvmpipe CPU raster, NOT real FPS]" % _worst_cpu_ms)
	# ceilings (fail only on a pathological regression).
	if _peak_static_mb > HEAP_STATIC_CEIL_MB:
		_fatal("MEMORY_STATIC peak %.1f MB exceeded ceiling %.0f MB (heap-under-render runaway)." % [_peak_static_mb, HEAP_STATIC_CEIL_MB])
	if _peak_render_mb > RENDER_MEM_CEIL_MB:
		_fatal("render tex+buf peak %.1f MB exceeded ceiling %.0f MB (VRAM runaway)." % [_peak_render_mb, RENDER_MEM_CEIL_MB])
	if _shots.is_empty():
		_fatal("no screenshots captured — the render loop never ran.")

func _finish() -> void:
	print("")
	if _fail == 0:
		print("==== SOAK-RENDER: PASS (clean rendered walk) ====")
	else:
		print("==== SOAK-RENDER: FAIL (%d issue(s)) ====" % _fail)
		for m in _fail_msgs:
			print("    - ", m)
	quit(1 if _fail > 0 else 0)

# SOAK_OUT (absolute host path, bind-mounted) if set; else user://soak (printed globalized so PNGs are findable).
func _resolve_out_dir() -> String:
	var env := OS.get_environment("SOAK_OUT")
	if env != "":
		DirAccess.make_dir_recursive_absolute(env)
		return env
	DirAccess.make_dir_recursive_absolute("user://soak")
	return ProjectSettings.globalize_path("user://soak")
