class_name HotbarHUD
extends CanvasLayer
## 9-slot hotbar bottom-center. Rebuilds slot visuals from the Inventory model
## on its signals; no per-frame polling.

var inventory: Inventory       # injected by Main BEFORE add_child

const SLOT_PX := 48
const SWATCH_PX := 34

var _panels: Array[PanelContainer] = []
var _swatches: Array[ColorRect] = []
var _labels: Array[Label] = []
var _normal_style: StyleBoxFlat
var _selected_style: StyleBoxFlat

func _ready() -> void:
	if inventory == null:
		return

	_normal_style = _make_style(Color(0.08, 0.08, 0.08, 0.72), Color(0.35, 0.35, 0.35, 0.85), 1)
	_selected_style = _make_style(Color(0.14, 0.14, 0.14, 0.88), Color(1.0, 1.0, 1.0, 1.0), 3)

	# CanvasLayer is not a Control, so anchor a full-rect Control first, then
	# bottom-center an HBoxContainer inside it (bottom-center -> no overlap with
	# the top-left thermometer).
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	root.add_child(hbox)
	hbox.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hbox.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hbox.offset_bottom = -16.0

	for i: int in range(Inventory.SLOT_COUNT):
		_build_slot(hbox)

	inventory.changed.connect(_refresh_all)
	inventory.selection_changed.connect(_refresh_selection)

	# Initial render after wiring the signals.
	_refresh_all()
	_update_selection()

func _build_slot(hbox: HBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
	panel.add_theme_stylebox_override("panel", _normal_style)
	hbox.add_child(panel)

	# Centered swatch.
	var center := CenterContainer.new()
	panel.add_child(center)

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(SWATCH_PX, SWATCH_PX)
	swatch.visible = false
	center.add_child(swatch)

	# Count label overlaid bottom-right (a second child of the PanelContainer
	# fills the same content rect and aligns its text to the corner).
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.visible = false
	panel.add_child(label)

	_panels.append(panel)
	_swatches.append(swatch)
	_labels.append(label)

func _make_style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(4)
	return sb

func _refresh_all() -> void:
	if inventory == null:
		return
	for i: int in range(_panels.size()):
		_refresh_slot(i)

func _refresh_slot(i: int) -> void:
	var s: Dictionary = inventory.slot(i)
	var id: int = s["id"]
	var cnt: int = s["count"]
	var swatch := _swatches[i]
	var label := _labels[i]
	if id == 0:
		swatch.visible = false
		label.visible = false
	else:
		swatch.color = BlockCatalog.color_of(id)
		swatch.visible = true
		label.text = str(cnt)
		label.visible = true

## Signal target: `selection_changed(index)` — refresh borders from the model.
func _refresh_selection(_index: int) -> void:
	_update_selection()

func _update_selection() -> void:
	if inventory == null:
		return
	var sel: int = inventory.selected_index()
	for i: int in range(_panels.size()):
		var st: StyleBoxFlat = _selected_style if i == sel else _normal_style
		_panels[i].add_theme_stylebox_override("panel", st)
