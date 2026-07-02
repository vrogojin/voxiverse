@tool
class_name GrassTextureBaker
extends RefCounted
## Procedurally bakes the 64x64 grass texture to res://assets/textures/grass.png.
##
## The committed PNG is produced by scripts/gen-grass-texture (pure Python, so it
## works with no engine present); this @tool script is the in-editor equivalent
## and the authoritative algorithm of record. Run it from an EditorScript, or
## headless:  godot --headless -s res://src/world/bake_grass.gd  (see that file).
##
## Look: green base + fBm value-noise mottle + subtle vertical blade streaks +
## slight low-frequency tint variation. Deterministic (SEED). Tiles reasonably.

const SIZE := 64
const SEED := 1337
const OUT_PATH := "res://assets/textures/grass.png"

static func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

static func _hash(ix: int, iy: int) -> float:
	ix = posmod(ix, SIZE)
	iy = posmod(iy, SIZE)
	var n := (ix * 374761393 + iy * 668265263 + SEED * 362437) & 0xFFFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65535.0

static func _value_noise(x: float, y: float, freq: float) -> float:
	var period := maxi(1, int(round(SIZE * freq)))
	var fx := x * freq
	var fy := y * freq
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := _smooth(fx - x0)
	var ty := _smooth(fy - y0)
	var scale := SIZE / period if period > 0 else 1
	var v00 := _hash(posmod(x0, period) * scale, posmod(y0, period) * scale)
	var v10 := _hash(posmod(x0 + 1, period) * scale, posmod(y0, period) * scale)
	var v01 := _hash(posmod(x0, period) * scale, posmod(y0 + 1, period) * scale)
	var v11 := _hash(posmod(x0 + 1, period) * scale, posmod(y0 + 1, period) * scale)
	var a := v00 + (v10 - v00) * tx
	var b := v01 + (v11 - v01) * tx
	return a + (b - a) * ty

static func _fbm(x: float, y: float) -> float:
	var total := 0.0
	var amp := 0.5
	var freq := 4.0 / SIZE
	for _i in 4:
		total += _value_noise(x, y, freq) * amp
		amp *= 0.5
		freq *= 2.0
	return total

static func _blade(x: float, y: float) -> float:
	return sin(x * 0.9 + _fbm(x * 1.7, y * 0.3) * 6.0) * 0.5 + 0.5

## Build and return the grass texture as an Image.
## High-contrast: light/dark grass patches + vertical blade streaks + fine
## micro-detail, so texturing is clearly visible on blocky voxel faces.
static func build_image() -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var pn := _value_noise(x, y, 2.0 / SIZE)   # light/dark patches
			var bd := _blade(x, y)                     # vertical blades
			var micro := _fbm(x, y)                    # fine detail
			var l := 0.45 + 0.55 * pn
			l *= (0.72 + 0.28 * bd)
			l += (micro - 0.5) * 0.28
			l = clampf(l, 0.15, 1.12)
			var r := 30.0 + 70.0 * l
			var g := 40.0 + 152.0 * l
			var bl := 24.0 + 46.0 * l
			img.set_pixel(x, y, Color(
				clampf(r, 0, 255) / 255.0,
				clampf(g, 0, 255) / 255.0,
				clampf(bl, 0, 255) / 255.0,
				1.0))
	return img

## Bake the image to OUT_PATH. Returns OK on success.
static func bake() -> int:
	var img := build_image()
	var abs_dir := ProjectSettings.globalize_path("res://assets/textures")
	DirAccess.make_dir_recursive_absolute(abs_dir)
	return img.save_png(OUT_PATH)
