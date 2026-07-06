class_name Crosshair
extends CanvasLayer
## A small "+" reticle painted at the exact centre of the screen — the fixed aim
## marker that replaced the world-space aimed-FACE highlight. A CanvasLayer renders
## to the viewport independently of any 3D transform, so the Player can own it as a
## plain child (mirroring how the HUDs are structured) and it always draws on top.
##
## The plus is a couple of thin white bars over a subtle dark outline, so it reads
## with high contrast on any background (bright sky, dark cave, mid grass) without a
## texture. It re-centres itself on every viewport resize, so it is correct at any
## resolution.

func _ready() -> void:
	# Full-rect Control so its centre is the screen centre; it never eats input.
	var reticle := _Reticle.new()
	reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(reticle)

## The Control that actually paints the "+". Full-rect, so `size * 0.5` is the
## screen centre; it repaints whenever the viewport (and thus its size) changes.
class _Reticle extends Control:
	const ARM := 7.0        # half-length of each arm, px (14 px tip-to-tip)
	const THICK := 2.0      # bar thickness, px
	const OUTLINE := 1.0    # dark border grown around each white bar, px

	func _ready() -> void:
		resized.connect(queue_redraw)   # re-centre the plus after any resolution change

	func _draw() -> void:
		var c := size * 0.5
		var white := Color(1.0, 1.0, 1.0, 0.9)
		var dark := Color(0.0, 0.0, 0.0, 0.5)
		var h := Rect2(c.x - ARM, c.y - THICK * 0.5, ARM * 2.0, THICK)
		var v := Rect2(c.x - THICK * 0.5, c.y - ARM, THICK, ARM * 2.0)
		# Dark outline first (bars grown by OUTLINE on every side), white on top.
		draw_rect(h.grow(OUTLINE), dark)
		draw_rect(v.grow(OUTLINE), dark)
		draw_rect(h, white)
		draw_rect(v, white)
