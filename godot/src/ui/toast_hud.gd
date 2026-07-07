class_name ToastHUD
extends CanvasLayer
## Transient one-line status text, centred low on the screen just above the hotbar.
## The portal linker posts its feedback here (armed / linked / unlinked / destroyed /
## rejected), but any system can call `show_toast(text)`. Purely a view — it holds no
## game state (PORTALS §3.0).

const HOLD_SEC := 2.6            # seconds the message stays fully opaque before fading
const FADE_SEC := 0.5           # fade-out duration after the hold

var _label: Label
var _time_left := 0.0

func _ready() -> void:
	layer = 64                  # above the hotbar (CanvasLayer default 1), below the prewarm overlay (128)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A band pinned to the bottom, lifted above the hotbar row (the hotbar sits in the
	# bottom ~SLOT_PX+36 px), reliably centred regardless of viewport size.
	_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_label.offset_left = 0.0
	_label.offset_right = 0.0
	_label.offset_top = -112.0
	_label.offset_bottom = -84.0
	_label.modulate.a = 0.0
	root.add_child(_label)
	set_process(true)

## Post a transient message. Replaces any currently-showing one (latest wins). Null-safe
## before `_ready` builds the label (no-op).
func show_toast(text: String) -> void:
	if _label == null:
		return
	_label.text = text
	_label.modulate.a = 1.0
	_time_left = HOLD_SEC + FADE_SEC

func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left -= delta
	if _time_left <= FADE_SEC:
		_label.modulate.a = clampf(_time_left / FADE_SEC, 0.0, 1.0)
