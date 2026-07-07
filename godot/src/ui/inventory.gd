class_name Inventory
extends RefCounted
## Minecraft-style hotbar inventory model. Pure data + signals; no nodes.
## Owned by Main (created in main.gd), injected into Player and HotbarHUD.

signal changed                       # any slot's content changed
signal selection_changed(index: int) # active hotbar slot moved

const SLOT_COUNT := 9
const MAX_STACK := 64

var _slots: Array[Dictionary] = []   # SLOT_COUNT entries: {"id": int, "count": int}; id 0 == empty
var _selected: int = 0

func _init() -> void:
	_slots.clear()
	for i: int in range(SLOT_COUNT):
		_slots.append({"id": 0, "count": 0})

## Add `count` items of `block_id`. Minecraft stacking: top up existing
## non-full stacks of the same id first (left to right), then fill empty slots.
## Returns the number that did NOT fit (0 = fully absorbed). Emits `changed`
## when anything was absorbed. block_id <= 0 is a no-op returning count.
func add(block_id: int, count: int = 1) -> int:
	if block_id == 0:
		return count                     # air / empty is never storable (was `<= 0`; tools are now negative)
	if count <= 0:
		return 0
	# ITEMS (negative ids — tools) are UNIQUE: capped at max_stack_of TOTAL across the whole
	# inventory (a tool is stack-1, so you hold at most one), never spread across slots. The
	# block path below is left byte-identical (the regression gate for existing inventory tests).
	if ItemCatalog.is_item(block_id):
		var cap: int = ItemCatalog.max_stack_of(block_id)
		var have := 0
		var slot_idx := -1
		for i: int in range(SLOT_COUNT):
			if _slots[i]["id"] == block_id:
				have += int(_slots[i]["count"])
				slot_idx = i
		var room := cap - have
		if room <= 0:
			return count                 # already at the item cap → all surplus
		if slot_idx < 0:
			for i: int in range(SLOT_COUNT):
				if _slots[i]["id"] == 0:
					slot_idx = i
					break
			if slot_idx < 0:
				return count             # no empty slot → all surplus
			_slots[slot_idx]["id"] = block_id
		var take: int = mini(room, count)
		_slots[slot_idx]["count"] = int(_slots[slot_idx]["count"]) + take
		changed.emit()
		return count - take
	var remaining: int = count
	var absorbed := false
	# Phase 1: top up existing non-full same-id stacks (left to right).
	for i: int in range(SLOT_COUNT):
		if remaining <= 0:
			break
		var s: Dictionary = _slots[i]
		var sid: int = s["id"]
		var scount: int = s["count"]
		if sid == block_id and scount < MAX_STACK:
			var take: int = mini(MAX_STACK - scount, remaining)
			s["count"] = scount + take
			remaining -= take
			absorbed = true
	# Phase 2: fill empty slots (left to right).
	for i: int in range(SLOT_COUNT):
		if remaining <= 0:
			break
		var s: Dictionary = _slots[i]
		var sid: int = s["id"]
		if sid == 0:
			var take: int = mini(MAX_STACK, remaining)
			s["id"] = block_id
			s["count"] = take
			remaining -= take
			absorbed = true
	if absorbed:
		changed.emit()
	return remaining

func selected_index() -> int:
	return _selected

func selected_block_id() -> int:
	var s: Dictionary = _slots[_selected]
	var id: int = s["id"]
	return id

func selected_count() -> int:
	var s: Dictionary = _slots[_selected]
	var cnt: int = s["count"]
	return cnt

## Remove `count` from the active slot. Returns false (and changes nothing)
## if the slot holds fewer than `count`. At 0 the slot resets to {"id":0,"count":0}.
## Emits `changed` on success.
func consume_selected(count: int = 1) -> bool:
	if count <= 0:
		return false
	var s: Dictionary = _slots[_selected]
	var scount: int = s["count"]
	if scount < count:
		return false
	var left: int = scount - count
	if left <= 0:
		s["id"] = 0
		s["count"] = 0
	else:
		s["count"] = left
	changed.emit()
	return true

func select_slot(i: int) -> void:
	var ni: int = clampi(i, 0, SLOT_COUNT - 1)
	if ni != _selected:
		_selected = ni
		selection_changed.emit(_selected)

func scroll(dir: int) -> void:
	var ni: int = posmod(_selected + dir, SLOT_COUNT)
	if ni != _selected:
		_selected = ni
		selection_changed.emit(_selected)

func slot(i: int) -> Dictionary:
	var ci: int = clampi(i, 0, SLOT_COUNT - 1)
	var s: Dictionary = _slots[ci]
	var id: int = s["id"]
	var cnt: int = s["count"]
	return {"id": id, "count": cnt}
